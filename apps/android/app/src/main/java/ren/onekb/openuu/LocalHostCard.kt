package ren.onekb.openuu

import android.content.Intent
import android.provider.Settings
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.ContentCopy
import androidx.compose.material.icons.rounded.Refresh
import androidx.compose.material.icons.rounded.Share
import androidx.compose.material.icons.rounded.Visibility
import androidx.compose.material.icons.rounded.VisibilityOff
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Checkbox
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.delay

private val CardBg = Color(0xFF121215)
private val ElevatedBg = Color(0xFF16161A)
private val PillSelectedBg = Color(0xFF23232B)
private val BorderCol = Color(0xFF27272E)
private val DividerCol = Color(0xFF232329)
private val PrimaryText = Color(0xFFF4F4F6)
private val SecondaryText = Color(0xFF8E8E98)
private val MutedText = Color(0xFF63636E)
private val GreenActive = Color(0xFF30D158)
private val AmberWarn = Color(0xFFFF9F0A)
private val RedDanger = Color(0xFFFF453A)
private val Obsidian = Color(0xFF09090B)

@Composable
fun LocalAndroidHostCard(
    viewModel: OpenUUViewModel,
    onRequestStartHost: () -> Unit
) {
    val context = LocalContext.current
    val identity by viewModel.identity.collectAsState()
    val hostState by viewModel.localHostState.collectAsState()
    val savedPin by viewModel.savedHostPin.collectAsState()
    val preferredMode by viewModel.preferredHostMode.collectAsState()
    val windowScale by viewModel.virtualWindowScale.collectAsState()
    val enhancedState by viewModel.enhancedEngineState.collectAsState()
    val isAccessibilityOn by viewModel.isAccessibilityEnabled.collectAsState()
    val suppressSafetyPrompt by viewModel.suppressHostAntiFraud.collectAsState()

    var showPinPlain by remember { mutableStateOf(true) }
    var showSafetyDialog by remember { mutableStateOf(false) }
    var showActivateDialog by remember { mutableStateOf(false) }
    var copiedBanner by remember { mutableStateOf("") }

    LaunchedEffect(copiedBanner) {
        if (copiedBanner.isNotEmpty()) {
            delay(1500L)
            copiedBanner = ""
        }
    }

    // Auto-close activation dialog once engine becomes active
    LaunchedEffect(enhancedState.isActive) {
        if (enhancedState.isActive && showActivateDialog) {
            delay(500L)
            showActivateDialog = false
        }
    }

    val effectiveMode = if (hostState.isRunning) hostState.hostMode else preferredMode
    val displayCode = identity.formattedCode.ifBlank { identity.deviceCode }.ifBlank { "--- --- ---" }
    val activePin = hostState.pin.ifBlank { savedPin }.ifBlank { "------" }
    val maskedPin = "•".repeat(activePin.length.coerceAtLeast(6))

    fun triggerStartForCurrentMode() {
        if (effectiveMode == AndroidHostMode.ENHANCED_MULTI_WINDOW && !enhancedState.isActive) {
            showActivateDialog = true
            return
        }
        if (suppressSafetyPrompt) {
            onRequestStartHost()
        } else {
            showSafetyDialog = true
        }
    }

    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.SpaceBetween
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp)
            ) {
                Text(
                    text = "允许远控本机",
                    style = MaterialTheme.typography.labelMedium,
                    color = SecondaryText,
                    modifier = Modifier.padding(start = 2.dp)
                )
                if (hostState.isRunning) {
                    Box(
                        modifier = Modifier
                            .size(6.dp)
                            .clip(CircleShape)
                            .background(GreenActive)
                    )
                    Text(
                        text = if (hostState.connectedClientName.isNotBlank()) {
                            "受控中 · ${hostState.connectedClientName}"
                        } else {
                            "等待连接 · ${hostState.hostMode.label}"
                        },
                        fontSize = 11.sp,
                        fontWeight = FontWeight.Medium,
                        color = GreenActive
                    )
                }
            }

            if (copiedBanner.isNotEmpty()) {
                Text(
                    text = copiedBanner,
                    fontSize = 11.sp,
                    color = GreenActive,
                    fontWeight = FontWeight.Medium
                )
            }
        }

        Surface(
            color = CardBg,
            shape = RoundedCornerShape(12.dp),
            border = BorderStroke(
                0.5.dp,
                if (hostState.isRunning) GreenActive.copy(alpha = 0.45f) else BorderCol
            ),
            modifier = Modifier.fillMaxWidth()
        ) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(12.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp)
            ) {
                // Mode Switcher Row (Dual-Mode: Basic Full-Screen vs Enhanced Multi-Window)
                HostModeSegmentedBar(
                    selectedMode = effectiveMode,
                    enabled = !hostState.isRunning,
                    enhancedActive = enhancedState.isActive,
                    onSelect = { nextMode ->
                        viewModel.setPreferredHostMode(nextMode)
                    }
                )

                // Row 1: Device Code + Access PIN + Start/Stop Toggle
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.SpaceBetween
                ) {
                    Column(
                        modifier = Modifier.weight(1f),
                        verticalArrangement = Arrangement.spacedBy(4.dp)
                    ) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(6.dp)
                        ) {
                            Text(
                                text = "设备码",
                                fontSize = 11.sp,
                                color = SecondaryText
                            )
                            Text(
                                text = displayCode,
                                fontFamily = FontFamily.Monospace,
                                fontSize = 15.sp,
                                fontWeight = FontWeight.SemiBold,
                                color = PrimaryText
                            )
                            IconButton(
                                onClick = {
                                    viewModel.copyToLocalClipboard("本机设备码", displayCode)
                                    copiedBanner = "已复制设备码"
                                },
                                modifier = Modifier.size(22.dp)
                            ) {
                                Icon(
                                    imageVector = Icons.Rounded.ContentCopy,
                                    contentDescription = "复制设备码",
                                    tint = SecondaryText,
                                    modifier = Modifier.size(13.dp)
                                )
                            }
                        }

                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(5.dp)
                        ) {
                            Text(
                                text = "访问码",
                                fontSize = 11.sp,
                                color = SecondaryText
                            )
                            Text(
                                text = if (showPinPlain) activePin else maskedPin,
                                fontFamily = FontFamily.Monospace,
                                fontSize = 13.5.sp,
                                fontWeight = FontWeight.Medium,
                                color = PrimaryText
                            )
                            IconButton(
                                onClick = { showPinPlain = !showPinPlain },
                                modifier = Modifier.size(22.dp)
                            ) {
                                Icon(
                                    imageVector = if (showPinPlain) Icons.Rounded.VisibilityOff else Icons.Rounded.Visibility,
                                    contentDescription = "显隐密码",
                                    tint = SecondaryText,
                                    modifier = Modifier.size(14.dp)
                                )
                            }
                            IconButton(
                                onClick = {
                                    viewModel.regenerateLocalHostPin()
                                    copiedBanner = "已刷新访问码"
                                },
                                modifier = Modifier.size(22.dp)
                            ) {
                                Icon(
                                    imageVector = Icons.Rounded.Refresh,
                                    contentDescription = "刷新密码",
                                    tint = SecondaryText,
                                    modifier = Modifier.size(14.dp)
                                )
                            }
                        }
                    }

                    if (hostState.isRunning) {
                        OutlinedButton(
                            onClick = { viewModel.stopLocalHost() },
                            shape = RoundedCornerShape(9.dp),
                            border = BorderStroke(0.5.dp, RedDanger.copy(alpha = 0.6f)),
                            colors = ButtonDefaults.outlinedButtonColors(contentColor = RedDanger),
                            contentPadding = PaddingValues(horizontal = 14.dp, vertical = 8.dp)
                        ) {
                            Text("停止被控", fontSize = 12.5.sp, fontWeight = FontWeight.SemiBold)
                        }
                    } else {
                        val needsActivateFirst =
                            effectiveMode == AndroidHostMode.ENHANCED_MULTI_WINDOW && !enhancedState.isActive
                        Button(
                            onClick = { triggerStartForCurrentMode() },
                            shape = RoundedCornerShape(9.dp),
                            colors = ButtonDefaults.buttonColors(
                                containerColor = PrimaryText,
                                contentColor = Obsidian
                            ),
                            contentPadding = PaddingValues(horizontal = 14.dp, vertical = 8.dp)
                        ) {
                            Text(
                                text = if (needsActivateFirst) "激活并开启" else "开启被控",
                                fontSize = 12.5.sp,
                                fontWeight = FontWeight.SemiBold
                            )
                        }
                    }
                }

                HorizontalDivider(thickness = 0.5.dp, color = DividerCol)

                // Row 2: Mode-specific capability pill + Share Invitation / Ticket Actions
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.SpaceBetween
                ) {
                    if (effectiveMode == AndroidHostMode.ENHANCED_MULTI_WINDOW) {
                        Surface(
                            onClick = { showActivateDialog = true },
                            color = ElevatedBg,
                            shape = RoundedCornerShape(7.dp),
                            border = BorderStroke(
                                0.5.dp,
                                if (enhancedState.isActive) GreenActive.copy(alpha = 0.4f) else AmberWarn.copy(alpha = 0.5f)
                            )
                        ) {
                            Row(
                                modifier = Modifier.padding(horizontal = 8.dp, vertical = 5.dp),
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(5.dp)
                            ) {
                                Box(
                                    modifier = Modifier
                                        .size(6.dp)
                                        .clip(CircleShape)
                                        .background(if (enhancedState.isActive) GreenActive else AmberWarn)
                                )
                                Text(
                                    text = if (enhancedState.isActive) {
                                        "${enhancedState.privilegeBadge} · 多应用多窗口"
                                    } else {
                                        "一键激活多窗口引擎"
                                    },
                                    fontSize = 11.5.sp,
                                    fontWeight = FontWeight.Medium,
                                    color = if (enhancedState.isActive) PrimaryText else AmberWarn
                                )
                            }
                        }
                    } else {
                        Surface(
                            onClick = {
                                runCatching {
                                    context.startActivity(
                                        Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS).apply {
                                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                        }
                                    )
                                }
                            },
                            color = ElevatedBg,
                            shape = RoundedCornerShape(7.dp),
                            border = BorderStroke(
                                0.5.dp,
                                if (isAccessibilityOn) GreenActive.copy(alpha = 0.35f) else AmberWarn.copy(alpha = 0.5f)
                            )
                        ) {
                            Row(
                                modifier = Modifier.padding(horizontal = 8.dp, vertical = 5.dp),
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(5.dp)
                            ) {
                                Box(
                                    modifier = Modifier
                                        .size(6.dp)
                                        .clip(CircleShape)
                                        .background(if (isAccessibilityOn) GreenActive else AmberWarn)
                                )
                                Text(
                                    text = if (isAccessibilityOn) "无障碍触控已就绪" else "开启无障碍触控",
                                    fontSize = 11.5.sp,
                                    fontWeight = FontWeight.Medium,
                                    color = if (isAccessibilityOn) PrimaryText else AmberWarn
                                )
                            }
                        }
                    }

                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(6.dp)
                    ) {
                        Surface(
                            onClick = {
                                val invite = "【OpenUU 远程连接】\n设备代码：$displayCode\n访问密码：$activePin"
                                viewModel.copyToLocalClipboard("远程连接信息", invite)
                                copiedBanner = "已复制设备码与密码"
                            },
                            color = ElevatedBg,
                            shape = RoundedCornerShape(7.dp),
                            border = BorderStroke(0.5.dp, BorderCol)
                        ) {
                            Row(
                                modifier = Modifier.padding(horizontal = 8.dp, vertical = 5.dp),
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(4.dp)
                            ) {
                                Icon(
                                    imageVector = Icons.Rounded.Share,
                                    contentDescription = null,
                                    tint = PrimaryText,
                                    modifier = Modifier.size(12.dp)
                                )
                                Text(
                                    text = "复制信息",
                                    fontSize = 11.5.sp,
                                    fontWeight = FontWeight.Medium,
                                    color = PrimaryText
                                )
                            }
                        }

                        if (hostState.isRunning && hostState.hostTicket.isNotBlank()) {
                            Surface(
                                onClick = {
                                    viewModel.copyToLocalClipboard("跨网连接串", hostState.hostTicket)
                                    copiedBanner = "已复制 openuu:// 连接串"
                                },
                                color = ElevatedBg,
                                shape = RoundedCornerShape(7.dp),
                                border = BorderStroke(0.5.dp, BorderCol)
                            ) {
                                Text(
                                    text = "连接串",
                                    fontSize = 11.5.sp,
                                    fontWeight = FontWeight.Medium,
                                    color = PrimaryText,
                                    modifier = Modifier.padding(horizontal = 8.dp, vertical = 5.dp)
                                )
                            }
                        }
                    }
                }

                // Row 3: Virtual Window Content Scale (Enhanced Mode) + Active Host Telemetry / Hint
                if (effectiveMode == AndroidHostMode.ENHANCED_MULTI_WINDOW) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.SpaceBetween
                    ) {
                        Text(
                            text = "虚拟窗口显示比例",
                            fontSize = 11.sp,
                            color = SecondaryText
                        )
                        Surface(
                            color = ElevatedBg,
                            shape = RoundedCornerShape(7.dp),
                            border = BorderStroke(0.5.dp, BorderCol)
                        ) {
                            Row(
                                modifier = Modifier.padding(2.dp),
                                horizontalArrangement = Arrangement.spacedBy(2.dp)
                            ) {
                                VirtualWindowScalePreset.entries.forEach { preset ->
                                    val selected = windowScale == preset
                                    Surface(
                                        onClick = { viewModel.setVirtualWindowScale(preset) },
                                        color = if (selected) PillSelectedBg else Color.Transparent,
                                        shape = RoundedCornerShape(5.dp)
                                    ) {
                                        Text(
                                            text = preset.label,
                                            fontSize = 10.5.sp,
                                            fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal,
                                            color = if (selected) PrimaryText else SecondaryText,
                                            modifier = Modifier.padding(horizontal = 8.dp, vertical = 3.dp)
                                        )
                                    }
                                }
                            }
                        }
                    }
                }

                if (hostState.isRunning) {
                    if (hostState.connectedClientName.isNotBlank()) {
                        Surface(
                            color = ElevatedBg,
                            shape = RoundedCornerShape(8.dp),
                            border = BorderStroke(0.5.dp, BorderCol),
                            modifier = Modifier.fillMaxWidth()
                        ) {
                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .padding(horizontal = 10.dp, vertical = 7.dp),
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.SpaceBetween
                            ) {
                                Column(modifier = Modifier.weight(1f)) {
                                    Text(
                                        text = "${hostState.connectedClientName} 正在远控本机",
                                        fontSize = 12.sp,
                                        fontWeight = FontWeight.SemiBold,
                                        color = PrimaryText,
                                        maxLines = 1,
                                        overflow = TextOverflow.Ellipsis
                                    )
                                    val streamTag = when {
                                        !hostState.isStreamingScreen -> "待命"
                                        hostState.hostMode == AndroidHostMode.ENHANCED_MULTI_WINDOW && hostState.openWindowCount > 1 ->
                                            "并发 ${hostState.openWindowCount} 窗口推流中"
                                        else -> "推流中"
                                    }
                                    val sub = listOfNotNull(
                                        hostState.hostMode.label,
                                        hostState.linkBadge.takeIf { it.isNotBlank() },
                                        streamTag,
                                        if (hostState.audioCaptureActive) "声音同步中" else null
                                    ).joinToString(" · ")
                                    Text(
                                        text = sub,
                                        fontFamily = FontFamily.Monospace,
                                        fontSize = 10.5.sp,
                                        color = SecondaryText,
                                        maxLines = 1
                                    )
                                }
                                TextButton(
                                    onClick = { viewModel.disconnectIncomingHostClient() },
                                    contentPadding = PaddingValues(horizontal = 8.dp, vertical = 2.dp)
                                ) {
                                    Text("断开对方", fontSize = 11.5.sp, color = RedDanger)
                                }
                            }
                        }
                    } else {
                        Text(
                            text = "${hostState.hostMode.label} · 端口 ${hostState.boundPort} · ${hostState.coordStatus}",
                            fontFamily = FontFamily.Monospace,
                            fontSize = 10.5.sp,
                            color = MutedText,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis
                        )
                    }
                    if (hostState.lastError.isNotBlank()) {
                        Surface(
                            onClick = {
                                runCatching {
                                    context.startActivity(
                                        Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS).apply {
                                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                        }
                                    )
                                }
                            },
                            color = CardBg,
                            shape = RoundedCornerShape(7.dp),
                            border = BorderStroke(0.5.dp, AmberWarn.copy(alpha = 0.55f)),
                            modifier = Modifier.fillMaxWidth()
                        ) {
                            Text(
                                text = hostState.lastError,
                                fontSize = 11.sp,
                                lineHeight = 15.5.sp,
                                color = AmberWarn,
                                modifier = Modifier.padding(horizontal = 8.dp, vertical = 6.dp)
                            )
                        }
                    }
                } else if (hostState.lastError.isNotBlank()) {
                    Text(
                        text = hostState.lastError,
                        fontSize = 11.5.sp,
                        color = RedDanger
                    )
                } else {
                    Text(
                        text = if (effectiveMode == AndroidHostMode.ENHANCED_MULTI_WINDOW) {
                            "内置多窗口引擎：支持多应用独立虚拟屏幕并发显示、微信主号与分身独立直开、免录屏弹窗"
                        } else {
                            "零配置基础整屏：自动锁定整屏共享，适合快速查看与操作整台手机屏幕"
                        },
                        fontSize = 11.sp,
                        lineHeight = 15.sp,
                        color = MutedText
                    )
                }
            }
        }
    }

    if (showSafetyDialog) {
        HostSafetyConfirmDialog(
            mode = effectiveMode,
            isAccessibilityOn = isAccessibilityOn,
            onDismiss = { showSafetyDialog = false },
            onOpenAccessibility = {
                runCatching {
                    context.startActivity(
                        Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS).apply {
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        }
                    )
                }
            },
            onConfirm = { dontShowAgain ->
                if (dontShowAgain) {
                    viewModel.setSuppressHostAntiFraud(true)
                }
                showSafetyDialog = false
                onRequestStartHost()
            }
        )
    }

    if (showActivateDialog) {
        EnhancedModeActivationDialog(
            state = enhancedState,
            onDismiss = { showActivateDialog = false },
            onStartAndClose = {
                showActivateDialog = false
                viewModel.startLocalHostEnhanced()
            }
        )
    }
}

@Composable
private fun HostModeSegmentedBar(
    selectedMode: AndroidHostMode,
    enabled: Boolean,
    enhancedActive: Boolean,
    onSelect: (AndroidHostMode) -> Unit
) {
    Surface(
        color = ElevatedBg,
        shape = RoundedCornerShape(9.dp),
        border = BorderStroke(0.5.dp, BorderCol),
        modifier = Modifier.fillMaxWidth()
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(3.dp),
            horizontalArrangement = Arrangement.spacedBy(4.dp)
        ) {
            AndroidHostMode.entries.forEach { mode ->
                val isSelected = selectedMode == mode
                Surface(
                    onClick = { if (enabled) onSelect(mode) },
                    color = if (isSelected) PillSelectedBg else Color.Transparent,
                    shape = RoundedCornerShape(7.dp),
                    border = if (isSelected) BorderStroke(0.5.dp, BorderCol) else null,
                    modifier = Modifier.weight(1f)
                ) {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(vertical = 6.dp, horizontal = 8.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.Center
                    ) {
                        if (mode == AndroidHostMode.ENHANCED_MULTI_WINDOW) {
                            Box(
                                modifier = Modifier
                                    .padding(end = 5.dp)
                                    .size(5.dp)
                                    .clip(CircleShape)
                                    .background(if (enhancedActive) GreenActive else AmberWarn)
                            )
                        }
                        Text(
                            text = if (mode == AndroidHostMode.BASIC_FULLSCREEN) {
                                "基础整屏模式"
                            } else {
                                "多窗口增强模式"
                            },
                            fontSize = 11.5.sp,
                            fontWeight = if (isSelected) FontWeight.SemiBold else FontWeight.Medium,
                            color = if (isSelected) PrimaryText else SecondaryText,
                            maxLines = 1
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun EnhancedModeActivationDialog(
    state: EnhancedEngineState,
    onDismiss: () -> Unit,
    onStartAndClose: () -> Unit
) {
    val context = LocalContext.current
    var pairingCodeInput by remember { mutableStateOf("") }
    var manualPortInput by remember { mutableStateOf("") }

    DisposableEffect(Unit) {
        WirelessAdbActivator.startWirelessDiscoveryAndNotification(context)
        onDispose {
            // Keep discovery running only if notification pairing is still waiting
        }
    }

    AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = ElevatedBg,
        titleContentColor = PrimaryText,
        textContentColor = SecondaryText,
        title = {
            Text(
                text = "激活多窗口增强模式",
                fontWeight = FontWeight.SemiBold,
                fontSize = 15.5.sp
            )
        },
        text = {
            Column(
                modifier = Modifier.verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(10.dp)
            ) {
                Text(
                    text = "无需安装第三方工具、无需连接电脑。激活一次即可在重启手机前持续使用：支持同时把多个应用投射为独立窗口、直接分别打开微信主号与分身（不再弹出选择框），且无需录屏与无障碍弹窗。",
                    fontSize = 12.sp,
                    lineHeight = 17.5.sp,
                    color = PrimaryText
                )

                // Live engine banner
                Surface(
                    color = CardBg,
                    shape = RoundedCornerShape(8.dp),
                    border = BorderStroke(
                        0.5.dp,
                        if (state.isActive) GreenActive.copy(alpha = 0.5f) else BorderCol
                    ),
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Column(
                        modifier = Modifier.padding(10.dp),
                        verticalArrangement = Arrangement.spacedBy(4.dp)
                    ) {
                        Text(
                            text = state.statusMessage,
                            fontSize = 12.sp,
                            fontWeight = FontWeight.SemiBold,
                            color = if (state.isActive) GreenActive else PrimaryText
                        )
                        val portSummary = buildList {
                            if (state.pairingPort > 0) add("配对端口: ${state.pairingPort}")
                            if (state.connectPort > 0) add("调试端口: ${state.connectPort}")
                        }.joinToString(" · ")
                        if (portSummary.isNotBlank()) {
                            Text(
                                text = portSummary,
                                fontFamily = FontFamily.Monospace,
                                fontSize = 11.sp,
                                color = GreenActive
                            )
                        }
                        if (state.lastError.isNotBlank()) {
                            Text(
                                text = state.lastError,
                                fontSize = 11.5.sp,
                                color = RedDanger
                            )
                        }
                    }
                }

                // Step-by-step wireless debugging guide + action button
                Surface(
                    color = CardBg,
                    shape = RoundedCornerShape(8.dp),
                    border = BorderStroke(0.5.dp, BorderCol),
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Column(
                        modifier = Modifier.padding(10.dp),
                        verticalArrangement = Arrangement.spacedBy(7.dp)
                    ) {
                        Text(
                            text = "方式一：本机无线调试激活（Android 11+ 免 Root）",
                            fontSize = 12.sp,
                            fontWeight = FontWeight.SemiBold,
                            color = PrimaryText
                        )
                        Text(
                            text = "1. 点击下方按钮进入「开发者选项 -> 无线调试」并开启\n" +
                                "2. 点击「使用配对码配对设备」（保持弹窗不关闭）\n" +
                                "3. 直接下拉顶部通知栏，在 OpenUU 通知中填入 6 位配对码即可完成激活\n" +
                                "提示：小米/红米请同时开启开发者选项中的「USB 调试（安全设置）」，OPPO/一加请开启底部「禁止权限监控」以允许远程点击",
                            fontSize = 11.5.sp,
                            lineHeight = 16.5.sp,
                            color = SecondaryText
                        )
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.spacedBy(8.dp)
                        ) {
                            Button(
                                onClick = {
                                    WirelessAdbActivator.startWirelessDiscoveryAndNotification(context)
                                    WirelessAdbActivator.openDeveloperSettings(context)
                                },
                                colors = ButtonDefaults.buttonColors(
                                    containerColor = PrimaryText,
                                    contentColor = Obsidian
                                ),
                                modifier = Modifier.weight(1f),
                                contentPadding = PaddingValues(horizontal = 10.dp, vertical = 7.dp)
                            ) {
                                Text("前往无线调试设置", fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
                            }

                            OutlinedButton(
                                onClick = {
                                    val manualP = manualPortInput.filter { it.isDigit() }.toIntOrNull() ?: 0
                                    WirelessAdbActivator.activateViaConnectPortAsync(context, manualP)
                                },
                                border = BorderStroke(0.5.dp, BorderCol),
                                contentPadding = PaddingValues(horizontal = 10.dp, vertical = 7.dp)
                            ) {
                                Text("已配对重连", fontSize = 12.sp, color = PrimaryText)
                            }
                        }

                        // Inline manual fallback (useful in split-screen / floating window mode)
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.spacedBy(6.dp),
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            OutlinedTextField(
                                value = pairingCodeInput,
                                onValueChange = { pairingCodeInput = it.filter(Char::isDigit).take(6) },
                                label = { Text("6位配对码(分屏可填)", fontSize = 10.5.sp) },
                                singleLine = true,
                                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                                modifier = Modifier.weight(1f)
                            )
                            OutlinedTextField(
                                value = manualPortInput,
                                onValueChange = { manualPortInput = it.filter(Char::isDigit).take(5) },
                                label = {
                                    Text(
                                        if (state.pairingPort > 0) "端口(${state.pairingPort})" else "端口(自动)",
                                        fontSize = 10.5.sp
                                    )
                                },
                                singleLine = true,
                                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                                modifier = Modifier.weight(0.85f)
                            )
                        }

                        if (pairingCodeInput.length == 6) {
                            Button(
                                onClick = {
                                    val p = manualPortInput.toIntOrNull() ?: 0
                                    WirelessAdbActivator.pairAndActivateAsync(
                                        context = context,
                                        pairingCode = pairingCodeInput,
                                        manualPairingPort = p
                                    )
                                },
                                enabled = !state.isBusy,
                                modifier = Modifier.fillMaxWidth(),
                                colors = ButtonDefaults.buttonColors(
                                    containerColor = GreenActive,
                                    contentColor = Obsidian
                                )
                            ) {
                                Text("立即配对并启动引擎", fontWeight = FontWeight.SemiBold, fontSize = 12.sp)
                            }
                        }
                    }
                }

                // Root quick option
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.SpaceBetween
                ) {
                    Text(
                        text = if (state.hasRootCandidate) "检测到本机含 Root 环境" else "方式二：已获取 Root 权限设备",
                        fontSize = 11.5.sp,
                        color = SecondaryText
                    )
                    OutlinedButton(
                        onClick = { WirelessAdbActivator.activateViaRootAsync(context) },
                        enabled = !state.isBusy,
                        border = BorderStroke(0.5.dp, BorderCol),
                        contentPadding = PaddingValues(horizontal = 10.dp, vertical = 5.dp)
                    ) {
                        Text("Root 一键激活", fontSize = 11.5.sp, color = PrimaryText)
                    }
                }
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text("关闭", color = SecondaryText)
            }
        },
        confirmButton = {
            if (state.isActive) {
                Button(
                    onClick = onStartAndClose,
                    colors = ButtonDefaults.buttonColors(
                        containerColor = GreenActive,
                        contentColor = Obsidian
                    )
                ) {
                    Text("立即开启多窗口被控", fontWeight = FontWeight.SemiBold)
                }
            }
        }
    )
}

@Composable
private fun HostSafetyConfirmDialog(
    mode: AndroidHostMode,
    isAccessibilityOn: Boolean,
    onDismiss: () -> Unit,
    onOpenAccessibility: () -> Unit,
    onConfirm: (Boolean) -> Unit
) {
    var dontAskAgain by remember { mutableStateOf(false) }

    AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = ElevatedBg,
        titleContentColor = PrimaryText,
        textContentColor = SecondaryText,
        title = {
            Text("开启本机被控安全确认", fontWeight = FontWeight.SemiBold, fontSize = 16.sp)
        },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Text(
                    text = if (mode == AndroidHostMode.ENHANCED_MULTI_WINDOW) {
                        "开启后，持有本机访问密码或已信任的设备将可通过多窗口增强模式远程打开并操作本机应用。请仅向您本人或受信任的设备提供设备码与访问密码。"
                    } else {
                        "开启后，持有本机访问密码或已信任的设备将可实时查看本机整屏画面（开启无障碍服务后可远程点击与输入）。请仅向您本人或受信任的设备提供设备码与访问密码。"
                    },
                    fontSize = 13.sp,
                    lineHeight = 19.sp,
                    color = PrimaryText
                )
                if (mode == AndroidHostMode.BASIC_FULLSCREEN && !isAccessibilityOn) {
                    Surface(
                        onClick = onOpenAccessibility,
                        color = CardBg,
                        shape = RoundedCornerShape(8.dp),
                        border = BorderStroke(0.5.dp, AmberWarn.copy(alpha = 0.5f)),
                        modifier = Modifier.fillMaxWidth()
                    ) {
                        Column(modifier = Modifier.padding(10.dp)) {
                            Text(
                                text = "提示：尚未开启「OpenUU 远程触控服务」",
                                fontSize = 12.sp,
                                fontWeight = FontWeight.SemiBold,
                                color = AmberWarn
                            )
                            Text(
                                text = "点此前往系统「无障碍」设置开启后即可远程点击与打字；不开启也可正常共享手机画面。",
                                fontSize = 11.5.sp,
                                color = SecondaryText
                            )
                        }
                    }
                }
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(4.dp)
                ) {
                    Checkbox(
                        checked = dontAskAgain,
                        onCheckedChange = { dontAskAgain = it }
                    )
                    Text(
                        text = "已知晓，下次不再提示",
                        fontSize = 12.sp,
                        color = SecondaryText
                    )
                }
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text("取消", color = SecondaryText)
            }
        },
        confirmButton = {
            Button(
                onClick = { onConfirm(dontAskAgain) },
                colors = ButtonDefaults.buttonColors(
                    containerColor = PrimaryText,
                    contentColor = Obsidian
                )
            ) {
                Text(
                    text = if (mode == AndroidHostMode.ENHANCED_MULTI_WINDOW) "立即开启被控" else "继续并授权整屏共享",
                    fontWeight = FontWeight.SemiBold
                )
            }
        }
    )
}
