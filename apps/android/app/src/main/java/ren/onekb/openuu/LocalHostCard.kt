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
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
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
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
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
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.delay

private val CardBg = Color(0xFF121215)
private val ElevatedBg = Color(0xFF16161A)
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
    val isAccessibilityOn by viewModel.isAccessibilityEnabled.collectAsState()
    val suppressSafetyPrompt by viewModel.suppressHostAntiFraud.collectAsState()

    var showPinPlain by remember { mutableStateOf(true) }
    var showSafetyDialog by remember { mutableStateOf(false) }
    var copiedBanner by remember { mutableStateOf("") }

    LaunchedEffect(copiedBanner) {
        if (copiedBanner.isNotEmpty()) {
            delay(1500L)
            copiedBanner = ""
        }
    }

    val displayCode = identity.formattedCode.ifBlank { identity.deviceCode }.ifBlank { "--- --- ---" }
    val activePin = hostState.pin.ifBlank { savedPin }.ifBlank { "------" }
    val maskedPin = "•".repeat(activePin.length.coerceAtLeast(6))

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
                            "等待连接"
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
                        Button(
                            onClick = {
                                if (suppressSafetyPrompt) {
                                    onRequestStartHost()
                                } else {
                                    showSafetyDialog = true
                                }
                            },
                            shape = RoundedCornerShape(9.dp),
                            colors = ButtonDefaults.buttonColors(
                                containerColor = PrimaryText,
                                contentColor = Obsidian
                            ),
                            contentPadding = PaddingValues(horizontal = 14.dp, vertical = 8.dp)
                        ) {
                            Text("开启被控", fontSize = 12.5.sp, fontWeight = FontWeight.SemiBold)
                        }
                    }
                }

                HorizontalDivider(thickness = 0.5.dp, color = DividerCol)

                // Row 2: Accessibility Touch Permission + Share Invitation / Ticket Actions
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.SpaceBetween
                ) {
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

                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(6.dp)
                    ) {
                        Surface(
                            onClick = {
                                val invite = "【OpenUU 远程协助】\n设备代码：$displayCode\n访问密码：$activePin"
                                viewModel.copyToLocalClipboard("远程协助邀请", invite)
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
                                    text = "复制邀请",
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

                // Row 3: Active Host Telemetry / Connected Client Banner
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
                                    val sub = listOfNotNull(
                                        hostState.linkBadge.takeIf { it.isNotBlank() },
                                        if (hostState.isStreamingScreen) "推流中" else "待命",
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
                            text = "端口 ${hostState.boundPort} · ${hostState.coordStatus}",
                            fontFamily = FontFamily.Monospace,
                            fontSize = 10.5.sp,
                            color = MutedText,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis
                        )
                    }
                } else if (hostState.lastError.isNotBlank()) {
                    Text(
                        text = hostState.lastError,
                        fontSize = 11.5.sp,
                        color = RedDanger
                    )
                }
            }
        }
    }

    if (showSafetyDialog) {
        HostSafetyConfirmDialog(
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
}

@Composable
private fun HostSafetyConfirmDialog(
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
            Text("开启本机被控安全提醒", fontWeight = FontWeight.SemiBold, fontSize = 16.sp)
        },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Text(
                    text = "开启后，持有本机访问密码或已信任的设备将可实时查看手机屏幕（若已开启无障碍服务，还可操作本机应用）。请勿向陌生人透露设备码与密码，谨防电信网络诈骗。",
                    fontSize = 13.sp,
                    lineHeight = 19.sp,
                    color = PrimaryText
                )
                if (!isAccessibilityOn) {
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
                        text = "已知晓安全风险，下次不再提示",
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
                Text("继续并授权录屏", fontWeight = FontWeight.SemiBold)
            }
        }
    )
}
