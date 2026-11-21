package ren.onekb.openuu

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.CloudOff
import androidx.compose.material.icons.rounded.ContentCopy
import androidx.compose.material.icons.rounded.ContentPaste
import androidx.compose.material.icons.rounded.Delete
import androidx.compose.material.icons.rounded.DesktopMac
import androidx.compose.material.icons.rounded.Devices
import androidx.compose.material.icons.rounded.Edit
import androidx.compose.material.icons.rounded.ErrorOutline
import androidx.compose.material.icons.rounded.LaptopMac
import androidx.compose.material.icons.rounded.Link
import androidx.compose.material.icons.rounded.Notifications
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.Public
import androidx.compose.material.icons.rounded.Refresh
import androidx.compose.material.icons.rounded.Save
import androidx.compose.material.icons.rounded.Settings
import androidx.compose.material.icons.rounded.Star
import androidx.compose.material.icons.rounded.StarBorder
import androidx.compose.material.icons.rounded.Terminal
import androidx.compose.material.icons.rounded.VerifiedUser
import androidx.compose.material.icons.rounded.Wifi
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationBarItemDefaults
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Scaffold
import androidx.compose.material3.ScaffoldDefaults
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
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
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import java.util.UUID

@Composable
fun MainScreen(
    viewModel: OpenUUViewModel,
    isImmersiveFullscreen: Boolean = false,
    isLandscape: Boolean = false,
    onPickFile: () -> Unit
) {
    val selectedTab by viewModel.selectedTab.collectAsState()
    val notificationBanner by viewModel.notificationBanner.collectAsState()
    val connectionPhase by viewModel.connectionPhase.collectAsState()

    Box(modifier = Modifier.fillMaxSize()) {
        Scaffold(
            containerColor = if (isImmersiveFullscreen) Color.Black else MaterialTheme.colorScheme.background,
            contentWindowInsets = if (isImmersiveFullscreen) {
                WindowInsets(0, 0, 0, 0)
            } else {
                ScaffoldDefaults.contentWindowInsets
            },
            bottomBar = {
                if (!isImmersiveFullscreen) {
                    OpenUUBottomNav(
                        selectedTab = selectedTab,
                        isConnected = connectionPhase.isConnected,
                        onSelectTab = { viewModel.selectTab(it) }
                    )
                }
            }
        ) { innerPadding ->
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(if (isImmersiveFullscreen) PaddingValues(0.dp) else innerPadding)
            ) {
                when (selectedTab) {
                    MainTab.CONNECT -> ConnectTabView(viewModel = viewModel)
                    MainTab.DEVICES -> DeviceBookTabView(viewModel = viewModel)
                    MainTab.REMOTE -> RemoteWorkspaceView(
                        viewModel = viewModel,
                        isImmersiveFullscreen = isImmersiveFullscreen,
                        isLandscape = isLandscape,
                        onPickFile = onPickFile
                    )
                    MainTab.SETTINGS -> SettingsAndLogsTabView(viewModel = viewModel)
                }
            }
        }

        // Top Remote Notification Banner Overlay
        AnimatedVisibility(
            visible = notificationBanner != null,
            enter = slideInVertically { -it } + fadeIn(),
            exit = slideOutVertically { -it } + fadeOut(),
            modifier = Modifier
                .align(Alignment.TopCenter)
                .then(if (isImmersiveFullscreen) Modifier else Modifier.statusBarsPadding())
                .padding(horizontal = 12.dp, vertical = 8.dp)
        ) {
            notificationBanner?.let { banner ->
                RemoteNotificationOverlayCard(
                    banner = banner,
                    onClick = {
                        viewModel.dismissNotificationBanner()
                        viewModel.selectTab(MainTab.REMOTE)
                    },
                    onDismiss = { viewModel.dismissNotificationBanner() }
                )
            }
        }
    }
}

@Composable
private fun OpenUUBottomNav(
    selectedTab: MainTab,
    isConnected: Boolean,
    onSelectTab: (MainTab) -> Unit
) {
    NavigationBar(
        containerColor = MaterialTheme.colorScheme.surface,
        tonalElevation = 0.dp
    ) {
        val items = listOf(
            Triple(MainTab.CONNECT, Icons.Rounded.Link, MainTab.CONNECT.label),
            Triple(MainTab.DEVICES, Icons.Rounded.Devices, MainTab.DEVICES.label),
            Triple(MainTab.REMOTE, Icons.Rounded.DesktopMac, MainTab.REMOTE.label),
            Triple(MainTab.SETTINGS, Icons.Rounded.Settings, MainTab.SETTINGS.label)
        )
        items.forEach { (tab, icon, label) ->
            val selected = selectedTab == tab
            NavigationBarItem(
                selected = selected,
                onClick = { onSelectTab(tab) },
                icon = {
                    Box {
                        Icon(imageVector = icon, contentDescription = label)
                        if (tab == MainTab.REMOTE && isConnected) {
                            Box(
                                modifier = Modifier
                                    .size(8.dp)
                                    .align(Alignment.TopEnd)
                                    .clip(CircleShape)
                                    .background(MaterialTheme.colorScheme.primary)
                            )
                        }
                    }
                },
                label = {
                    Text(
                        text = label,
                        style = MaterialTheme.typography.labelSmall,
                        maxLines = 1
                    )
                },
                colors = NavigationBarItemDefaults.colors(
                    selectedIconColor = MaterialTheme.colorScheme.primary,
                    selectedTextColor = MaterialTheme.colorScheme.primary,
                    indicatorColor = MaterialTheme.colorScheme.primaryContainer.copy(alpha = 0.65f),
                    unselectedIconColor = MaterialTheme.colorScheme.onSurfaceVariant,
                    unselectedTextColor = MaterialTheme.colorScheme.onSurfaceVariant
                )
            )
        }
    }
}

@Composable
private fun RemoteNotificationOverlayCard(
    banner: RemoteNotificationBanner,
    onClick: () -> Unit,
    onDismiss: () -> Unit
) {
    Card(
        onClick = onClick,
        shape = RoundedCornerShape(16.dp),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerHighest),
        border = BorderStroke(1.dp, MaterialTheme.colorScheme.primary.copy(alpha = 0.6f)),
        elevation = CardDefaults.cardElevation(defaultElevation = 8.dp),
        modifier = Modifier.fillMaxWidth()
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 14.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            Box(
                modifier = Modifier
                    .size(36.dp)
                    .clip(CircleShape)
                    .background(MaterialTheme.colorScheme.primaryContainer),
                contentAlignment = Alignment.Center
            ) {
                Icon(
                    imageVector = Icons.Rounded.Notifications,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.primary,
                    modifier = Modifier.size(20.dp)
                )
            }
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = banner.title,
                    style = MaterialTheme.typography.titleSmall,
                    color = MaterialTheme.colorScheme.onSurface,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )
                if (banner.subtitle.isNotBlank()) {
                    Text(
                        text = banner.subtitle,
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.primary,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis
                    )
                }
                if (banner.body.isNotBlank()) {
                    Text(
                        text = banner.body,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis
                    )
                }
            }
            IconButton(onClick = onDismiss, modifier = Modifier.size(28.dp)) {
                Icon(
                    imageVector = Icons.Rounded.Close,
                    contentDescription = "关闭通知",
                    modifier = Modifier.size(16.dp)
                )
            }
        }
    }
}

// =========================================================================
// TAB 1: CONNECT (Smart Connect, LAN mDNS Discovery, Trusted Peers)
// =========================================================================

@Composable
private fun ConnectTabView(viewModel: OpenUUViewModel) {
    val connectionPhase by viewModel.connectionPhase.collectAsState()
    val linkBadge by viewModel.linkBadge.collectAsState()
    val discoveredPeers by viewModel.discoveredPeers.collectAsState()
    val identity by viewModel.identity.collectAsState()

    var targetField by remember { mutableStateOf(TextFieldValue("")) }
    val targetInput = targetField.text
    var pinInput by remember { mutableStateOf("") }

    LazyColumn(
        modifier = Modifier
            .fillMaxSize()
            .statusBarsPadding(),
        contentPadding = PaddingValues(16.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp)
    ) {
        // Brand Header
        item {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.SpaceBetween
            ) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                    modifier = Modifier.weight(1f)
                ) {
                    Image(
                        painter = painterResource(id = R.drawable.openuu_brand_icon),
                        contentDescription = "OpenUU",
                        contentScale = ContentScale.Fit,
                        modifier = Modifier
                            .size(48.dp)
                            .clip(RoundedCornerShape(12.dp))
                    )
                    Column {
                        Text(
                            text = "OpenUU",
                            style = MaterialTheme.typography.headlineSmall,
                            color = MaterialTheme.colorScheme.onBackground
                        )
                        Text(
                            text = "工作伴侣，永久免费。",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                }
                if (identity.formattedCode.isNotBlank()) {
                    Surface(
                        color = MaterialTheme.colorScheme.surfaceContainerHigh,
                        shape = RoundedCornerShape(10.dp),
                        border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant)
                    ) {
                        Text(
                            text = "本机 ${identity.formattedCode}",
                            style = MaterialTheme.typography.labelSmall,
                            fontFamily = FontFamily.Monospace,
                            color = MaterialTheme.colorScheme.primary,
                            modifier = Modifier.padding(horizontal = 10.dp, vertical = 6.dp)
                        )
                    }
                }
            }
        }

        // Connection Status Banner
        if (connectionPhase !is ConnectionPhase.Idle) {
            item {
                ConnectionStatusBanner(
                    phase = connectionPhase,
                    linkBadge = linkBadge,
                    onEnterRemote = { viewModel.selectTab(MainTab.REMOTE) },
                    onDisconnect = { viewModel.disconnect() }
                )
            }
        }

        // Smart Connect Card
        item {
            Card(
                shape = RoundedCornerShape(18.dp),
                colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainer),
                border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant)
            ) {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(16.dp),
                    verticalArrangement = Arrangement.spacedBy(12.dp)
                ) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.SpaceBetween,
                        modifier = Modifier.fillMaxWidth()
                    ) {
                        Text(
                            text = "智能连接",
                            style = MaterialTheme.typography.titleMedium,
                            color = MaterialTheme.colorScheme.onSurface
                        )
                        FilledTonalButton(
                            onClick = {
                                val pasted = DeviceBookRepository.formatTargetInput(viewModel.readLocalClipboardText().trim())
                                if (pasted.isNotEmpty()) {
                                    targetField = TextFieldValue(pasted, selection = TextRange(pasted.length))
                                }
                            },
                            contentPadding = PaddingValues(horizontal = 10.dp, vertical = 4.dp),
                            shape = RoundedCornerShape(10.dp)
                        ) {
                            Icon(
                                imageVector = Icons.Rounded.ContentPaste,
                                contentDescription = null,
                                modifier = Modifier.size(15.dp)
                            )
                            Spacer(modifier = Modifier.width(4.dp))
                            Text("一键粘贴", style = MaterialTheme.typography.labelMedium)
                        }
                    }

                    OutlinedTextField(
                        value = targetField,
                        onValueChange = { targetField = formatTargetTextFieldValue(it, targetField.text) },
                        label = { Text("9 位设备码 / openuu:// 连接串 / IP:Port") },
                        placeholder = { Text("例如 839 201 475 或 192.168.1.10") },
                        singleLine = true,
                        shape = RoundedCornerShape(12.dp),
                        modifier = Modifier.fillMaxWidth(),
                        trailingIcon = {
                            if (targetInput.isNotEmpty()) {
                                IconButton(onClick = { targetField = TextFieldValue("") }) {
                                    Icon(Icons.Rounded.Close, contentDescription = "清除", modifier = Modifier.size(18.dp))
                                }
                            }
                        },
                        colors = OutlinedTextFieldDefaults.colors(
                            focusedContainerColor = MaterialTheme.colorScheme.surfaceContainerLow,
                            unfocusedContainerColor = MaterialTheme.colorScheme.surfaceContainerLow
                        )
                    )

                    OutlinedTextField(
                        value = pinInput,
                        onValueChange = { pinInput = it },
                        label = { Text("配对码 / 访问密码（已信任设备可留空）") },
                        placeholder = { Text("6 位数字或字母配对码") },
                        singleLine = true,
                        shape = RoundedCornerShape(12.dp),
                        modifier = Modifier.fillMaxWidth(),
                        colors = OutlinedTextFieldDefaults.colors(
                            focusedContainerColor = MaterialTheme.colorScheme.surfaceContainerLow,
                            unfocusedContainerColor = MaterialTheme.colorScheme.surfaceContainerLow
                        )
                    )

                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.spacedBy(10.dp)
                    ) {
                        Button(
                            onClick = {
                                viewModel.connectSmart(
                                    target = targetInput,
                                    defaultPort = OpenUUConstants.DEFAULT_PORT,
                                    pin = pinInput
                                )
                            },
                            enabled = targetInput.isNotBlank() && !connectionPhase.isConnecting,
                            shape = RoundedCornerShape(12.dp),
                            modifier = Modifier.weight(1f)
                        ) {
                            Icon(Icons.Rounded.PlayArrow, contentDescription = null, modifier = Modifier.size(18.dp))
                            Spacer(modifier = Modifier.width(6.dp))
                            Text("立即连接")
                        }
                        OutlinedButton(
                            onClick = {
                                val cleanTarget = DeviceBookRepository.sanitizeTargetForUse(targetInput)
                                if (cleanTarget.isNotBlank()) {
                                    viewModel.upsertDeviceBookEntry(
                                        DeviceBookEntry(
                                            id = UUID.randomUUID().toString(),
                                            alias = cleanTarget.take(24),
                                            target = cleanTarget,
                                            port = OpenUUConstants.DEFAULT_PORT,
                                            savedPin = pinInput.trim()
                                        )
                                    )
                                }
                            },
                            enabled = DeviceBookRepository.sanitizeTargetForUse(targetInput).isNotBlank(),
                            shape = RoundedCornerShape(12.dp)
                        ) {
                            Icon(Icons.Rounded.Save, contentDescription = null, modifier = Modifier.size(16.dp))
                            Spacer(modifier = Modifier.width(4.dp))
                            Text("收藏")
                        }
                    }
                }
            }
        }

        // LAN mDNS Discovered Macs Section
        item {
            SectionTitleRow(
                icon = Icons.Rounded.Wifi,
                title = "局域网发现 (mDNS)",
                trailingText = "${discoveredPeers.size} 台"
            )
        }

        if (discoveredPeers.isEmpty()) {
            item {
                Card(
                    shape = RoundedCornerShape(14.dp),
                    colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerLow),
                    border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant)
                ) {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(16.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(12.dp)
                    ) {
                        CircularProgressIndicator(
                            modifier = Modifier.size(18.dp),
                            strokeWidth = 2.dp,
                            color = MaterialTheme.colorScheme.primary
                        )
                        Text(
                            text = "正在扫描同一 Wi-Fi 下的 Mac 主机...",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                }
            }
        } else {
            items(discoveredPeers, key = { it.deviceId.ifBlank { "${it.primaryAddress}:${it.port}" } }) { peer ->
                Card(
                    shape = RoundedCornerShape(14.dp),
                    colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainer),
                    border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant)
                ) {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(14.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(12.dp)
                    ) {
                        Box(
                            modifier = Modifier
                                .size(40.dp)
                                .clip(RoundedCornerShape(10.dp))
                                .background(MaterialTheme.colorScheme.primaryContainer),
                            contentAlignment = Alignment.Center
                        ) {
                            Icon(
                                imageVector = Icons.Rounded.LaptopMac,
                                contentDescription = null,
                                tint = MaterialTheme.colorScheme.primary
                            )
                        }
                        Column(modifier = Modifier.weight(1f)) {
                            Text(
                                text = peer.deviceName,
                                style = MaterialTheme.typography.titleSmall,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis
                            )
                            Text(
                                text = buildString {
                                    append("${peer.primaryAddress}:${peer.port}")
                                    if (peer.deviceCode.length == 9) {
                                        append(" · ${peer.deviceCode}")
                                    }
                                },
                                style = MaterialTheme.typography.bodySmall,
                                fontFamily = FontFamily.Monospace,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis
                            )
                        }
                        FilledTonalButton(
                            onClick = {
                                if (peer.primaryAddress.isNotBlank()) {
                                    viewModel.connectDirect(peer.primaryAddress, peer.port, pinInput)
                                } else {
                                    viewModel.connectSmart(
                                        peer.deviceCode.ifBlank { peer.deviceId },
                                        peer.port,
                                        pinInput
                                    )
                                }
                            },
                            shape = RoundedCornerShape(10.dp),
                            contentPadding = PaddingValues(horizontal = 12.dp, vertical = 6.dp)
                        ) {
                            Text("连接", style = MaterialTheme.typography.labelMedium)
                        }
                    }
                }
            }
        }

        // Trusted Peers Section
        item {
            SectionTitleRow(
                icon = Icons.Rounded.VerifiedUser,
                title = "已信任主机（免密重连）",
                trailingText = "${identity.trustedPeers.size} 台"
            )
        }

        if (identity.trustedPeers.isEmpty()) {
            item {
                Text(
                    text = "首次输入配对码连接成功后，主机将自动加入信任列表，后续可一键免密重连。",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(horizontal = 4.dp)
                )
            }
        } else {
            items(identity.trustedPeers, key = { it.deviceId.ifBlank { it.endpointId } }) { peer ->
                Card(
                    shape = RoundedCornerShape(14.dp),
                    colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainer),
                    border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant)
                ) {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(14.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(10.dp)
                    ) {
                        Box(
                            modifier = Modifier
                                .size(38.dp)
                                .clip(RoundedCornerShape(10.dp))
                                .background(MaterialTheme.colorScheme.secondaryContainer),
                            contentAlignment = Alignment.Center
                        ) {
                            Icon(
                                imageVector = Icons.Rounded.VerifiedUser,
                                contentDescription = null,
                                tint = MaterialTheme.colorScheme.onSecondaryContainer,
                                modifier = Modifier.size(20.dp)
                            )
                        }
                        Column(modifier = Modifier.weight(1f)) {
                            Text(
                                text = peer.deviceName,
                                style = MaterialTheme.typography.titleSmall,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis
                            )
                            Text(
                                text = peer.deviceCode.takeIf { it.length == 9 }
                                    ?.let { "${it.substring(0, 3)} ${it.substring(3, 6)} ${it.substring(6, 9)}" }
                                    ?: peer.deviceId.take(18),
                                style = MaterialTheme.typography.bodySmall,
                                fontFamily = FontFamily.Monospace,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                maxLines = 1
                            )
                        }
                        Button(
                            onClick = {
                                viewModel.connectSmart(
                                    target = peer.connectTarget,
                                    defaultPort = OpenUUConstants.DEFAULT_PORT,
                                    pin = ""
                                )
                            },
                            shape = RoundedCornerShape(10.dp),
                            contentPadding = PaddingValues(horizontal = 12.dp, vertical = 6.dp)
                        ) {
                            Text("重连", style = MaterialTheme.typography.labelMedium)
                        }
                        IconButton(
                            onClick = { viewModel.removeTrustedPeer(peer.deviceId) },
                            modifier = Modifier.size(34.dp)
                        ) {
                            Icon(
                                imageVector = Icons.Rounded.Delete,
                                contentDescription = "撤销信任",
                                tint = MaterialTheme.colorScheme.error,
                                modifier = Modifier.size(18.dp)
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun ConnectionStatusBanner(
    phase: ConnectionPhase,
    linkBadge: String,
    onEnterRemote: () -> Unit,
    onDisconnect: () -> Unit
) {
    val containerColor = when (phase) {
        is ConnectionPhase.Connected -> Color(0xFF064E3B)
        is ConnectionPhase.Connecting -> MaterialTheme.colorScheme.secondaryContainer
        is ConnectionPhase.Error -> MaterialTheme.colorScheme.errorContainer
        ConnectionPhase.Idle -> MaterialTheme.colorScheme.surfaceContainer
    }
    Card(
        shape = RoundedCornerShape(14.dp),
        colors = CardDefaults.cardColors(containerColor = containerColor)
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 14.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp)
        ) {
            when (phase) {
                is ConnectionPhase.Connecting -> {
                    CircularProgressIndicator(
                        modifier = Modifier.size(20.dp),
                        strokeWidth = 2.dp,
                        color = MaterialTheme.colorScheme.onSecondaryContainer
                    )
                    Text(
                        text = phase.detail,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSecondaryContainer,
                        modifier = Modifier.weight(1f)
                    )
                    TextButton(onClick = onDisconnect) {
                        Text("取消", color = MaterialTheme.colorScheme.onSecondaryContainer)
                    }
                }
                is ConnectionPhase.Connected -> {
                    Icon(
                        imageVector = Icons.Rounded.Check,
                        contentDescription = null,
                        tint = Color(0xFF6EE7B7)
                    )
                    Column(modifier = Modifier.weight(1f)) {
                        Text(
                            text = "已连接: ${phase.hostName}",
                            style = MaterialTheme.typography.titleSmall,
                            color = Color.White
                        )
                        if (linkBadge.isNotBlank()) {
                            Text(
                                text = linkBadge,
                                style = MaterialTheme.typography.labelSmall,
                                color = Color(0xFFA7F3D0)
                            )
                        }
                    }
                    FilledTonalButton(
                        onClick = onEnterRemote,
                        contentPadding = PaddingValues(horizontal = 10.dp, vertical = 4.dp)
                    ) {
                        Text("远控", style = MaterialTheme.typography.labelMedium)
                    }
                    IconButton(onClick = onDisconnect, modifier = Modifier.size(30.dp)) {
                        Icon(
                            imageVector = Icons.Rounded.Close,
                            contentDescription = "断开",
                            tint = Color.White,
                            modifier = Modifier.size(18.dp)
                        )
                    }
                }
                is ConnectionPhase.Error -> {
                    Icon(
                        imageVector = Icons.Rounded.ErrorOutline,
                        contentDescription = null,
                        tint = MaterialTheme.colorScheme.onErrorContainer
                    )
                    Text(
                        text = phase.reason,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onErrorContainer,
                        modifier = Modifier.weight(1f)
                    )
                }
                ConnectionPhase.Idle -> Unit
            }
        }
    }
}

// =========================================================================
// TAB 2: DEVICE BOOK (Saved Devices, Online Probe, Add/Edit/Delete)
// =========================================================================

@Composable
private fun DeviceBookTabView(viewModel: OpenUUViewModel) {
    val devices by viewModel.deviceBook.collectAsState()
    val probeResults by viewModel.probeResults.collectAsState()

    var editingEntry by remember { mutableStateOf<DeviceBookEntry?>(null) }
    var showAddDialog by remember { mutableStateOf(false) }

    LaunchedEffect(Unit) {
        viewModel.probeDeviceBookOnline()
    }

    LazyColumn(
        modifier = Modifier
            .fillMaxSize()
            .statusBarsPadding(),
        contentPadding = PaddingValues(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp)
    ) {
        item {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.SpaceBetween
            ) {
                Column {
                    Text(
                        text = "设备簿",
                        style = MaterialTheme.typography.headlineSmall
                    )
                    Text(
                        text = "共 ${devices.size} 台常用 Mac",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    FilledTonalButton(
                        onClick = { viewModel.probeDeviceBookOnline() },
                        shape = RoundedCornerShape(10.dp),
                        contentPadding = PaddingValues(horizontal = 12.dp, vertical = 6.dp)
                    ) {
                        Icon(Icons.Rounded.Refresh, contentDescription = null, modifier = Modifier.size(16.dp))
                        Spacer(modifier = Modifier.width(4.dp))
                        Text("探测状态", style = MaterialTheme.typography.labelMedium)
                    }
                    Button(
                        onClick = {
                            editingEntry = null
                            showAddDialog = true
                        },
                        shape = RoundedCornerShape(10.dp),
                        contentPadding = PaddingValues(horizontal = 12.dp, vertical = 6.dp)
                    ) {
                        Icon(Icons.Rounded.Add, contentDescription = null, modifier = Modifier.size(16.dp))
                        Spacer(modifier = Modifier.width(4.dp))
                        Text("添加", style = MaterialTheme.typography.labelMedium)
                    }
                }
            }
        }

        if (devices.isEmpty()) {
            item {
                Card(
                    shape = RoundedCornerShape(16.dp),
                    colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainer),
                    border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant)
                ) {
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(28.dp),
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        Icon(
                            imageVector = Icons.Rounded.Devices,
                            contentDescription = null,
                            tint = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.size(36.dp)
                        )
                        Text(
                            text = "暂无保存的设备",
                            style = MaterialTheme.typography.titleSmall
                        )
                        Text(
                            text = "点击右上角「添加」手动录入 9 位设备码或局域网 IP，连接成功的主机也会自动同步到这里。",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                }
            }
        } else {
            items(devices, key = { it.id }) { entry ->
                val probe = probeResults[entry.id]
                DeviceBookCard(
                    entry = entry,
                    probe = probe,
                    onConnect = {
                        viewModel.connectSmart(entry.target, entry.port, entry.savedPin)
                    },
                    onToggleFavorite = { viewModel.toggleDeviceFavorite(entry.id) },
                    onEdit = {
                        editingEntry = entry
                        showAddDialog = true
                    },
                    onDelete = { viewModel.deleteDeviceBookEntry(entry.id) }
                )
            }
        }
    }

    if (showAddDialog) {
        DeviceBookEditDialog(
            initial = editingEntry,
            onDismiss = { showAddDialog = false },
            onSave = { updated ->
                viewModel.upsertDeviceBookEntry(updated)
                showAddDialog = false
            }
        )
    }
}

@Composable
private fun DeviceBookCard(
    entry: DeviceBookEntry,
    probe: DeviceProbeResult?,
    onConnect: () -> Unit,
    onToggleFavorite: () -> Unit,
    onEdit: () -> Unit,
    onDelete: () -> Unit
) {
    val badgeBg: Color
    val badgeFg: Color
    val badgeIcon: ImageVector
    val badgeText: String

    when (probe?.via) {
        "lan" -> {
            badgeBg = Color(0xFF064E3B)
            badgeFg = Color(0xFF6EE7B7)
            badgeIcon = Icons.Rounded.Wifi
            badgeText = "局域网"
        }
        "wan" -> {
            badgeBg = Color(0xFF312E81)
            badgeFg = Color(0xFFC7D2FE)
            badgeIcon = Icons.Rounded.Public
            badgeText = "跨网在线"
        }
        else -> {
            badgeBg = MaterialTheme.colorScheme.surfaceVariant
            badgeFg = MaterialTheme.colorScheme.onSurfaceVariant
            badgeIcon = Icons.Rounded.CloudOff
            badgeText = "离线"
        }
    }

    Card(
        shape = RoundedCornerShape(16.dp),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainer),
        border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant)
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(14.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp)
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically
            ) {
                IconButton(
                    onClick = onToggleFavorite,
                    modifier = Modifier.size(32.dp)
                ) {
                    Icon(
                        imageVector = if (entry.favorite) Icons.Rounded.Star else Icons.Rounded.StarBorder,
                        contentDescription = "置顶收藏",
                        tint = if (entry.favorite) Color(0xFFFBBF24) else MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
                Spacer(modifier = Modifier.width(6.dp))
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        text = entry.alias,
                        style = MaterialTheme.typography.titleSmall,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis
                    )
                    Text(
                        text = entry.displayTarget,
                        style = MaterialTheme.typography.bodySmall,
                        fontFamily = FontFamily.Monospace,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis
                    )
                }
                Surface(
                    color = badgeBg,
                    shape = RoundedCornerShape(8.dp)
                ) {
                    Row(
                        modifier = Modifier.padding(horizontal = 8.dp, vertical = 4.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(4.dp)
                    ) {
                        Icon(badgeIcon, contentDescription = null, tint = badgeFg, modifier = Modifier.size(13.dp))
                        Text(badgeText, style = MaterialTheme.typography.labelSmall, color = badgeFg)
                    }
                }
            }

            if (entry.notes.isNotBlank()) {
                Text(
                    text = entry.notes,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis
                )
            }

            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                    IconButton(onClick = onEdit, modifier = Modifier.size(34.dp)) {
                        Icon(
                            imageVector = Icons.Rounded.Edit,
                            contentDescription = "编辑",
                            tint = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.size(18.dp)
                        )
                    }
                    IconButton(onClick = onDelete, modifier = Modifier.size(34.dp)) {
                        Icon(
                            imageVector = Icons.Rounded.Delete,
                            contentDescription = "删除",
                            tint = MaterialTheme.colorScheme.error,
                            modifier = Modifier.size(18.dp)
                        )
                    }
                }
                Button(
                    onClick = onConnect,
                    shape = RoundedCornerShape(10.dp),
                    contentPadding = PaddingValues(horizontal = 16.dp, vertical = 6.dp)
                ) {
                    Icon(Icons.Rounded.PlayArrow, contentDescription = null, modifier = Modifier.size(16.dp))
                    Spacer(modifier = Modifier.width(4.dp))
                    Text("连接", style = MaterialTheme.typography.labelMedium)
                }
            }
        }
    }
}

@Composable
private fun DeviceBookEditDialog(
    initial: DeviceBookEntry?,
    onDismiss: () -> Unit,
    onSave: (DeviceBookEntry) -> Unit
) {
    var alias by remember(initial) { mutableStateOf(initial?.alias.orEmpty()) }
    var targetField by remember(initial) {
        val formatted = DeviceBookRepository.formatTargetInput(initial?.target.orEmpty())
        mutableStateOf(TextFieldValue(formatted, selection = TextRange(formatted.length)))
    }
    val target = targetField.text
    var portText by remember(initial) {
        mutableStateOf((initial?.port ?: OpenUUConstants.DEFAULT_PORT).toString())
    }
    var savedPin by remember(initial) { mutableStateOf(initial?.savedPin.orEmpty()) }
    var notes by remember(initial) { mutableStateOf(initial?.notes.orEmpty()) }
    var favorite by remember(initial) { mutableStateOf(initial?.favorite ?: false) }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = {
            Text(if (initial == null) "添加远程设备" else "编辑设备")
        },
        text = {
            Column(
                modifier = Modifier.verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(10.dp)
            ) {
                OutlinedTextField(
                    value = alias,
                    onValueChange = { alias = it },
                    label = { Text("设备名称 / 备注别名") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth()
                )
                OutlinedTextField(
                    value = targetField,
                    onValueChange = { targetField = formatTargetTextFieldValue(it, targetField.text) },
                    label = { Text("9 位设备码 / openuu:// / IP") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth()
                )
                OutlinedTextField(
                    value = portText,
                    onValueChange = { portText = it.filter { ch -> ch.isDigit() } },
                    label = { Text("默认端口") },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                    modifier = Modifier.fillMaxWidth()
                )
                OutlinedTextField(
                    value = savedPin,
                    onValueChange = { savedPin = it },
                    label = { Text("访问密码 / PIN（可选）") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth()
                )
                OutlinedTextField(
                    value = notes,
                    onValueChange = { notes = it },
                    label = { Text("备注（可选）") },
                    maxLines = 2,
                    modifier = Modifier.fillMaxWidth()
                )
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.SpaceBetween
                ) {
                    Text("置顶收藏", style = MaterialTheme.typography.bodyMedium)
                    Switch(checked = favorite, onCheckedChange = { favorite = it })
                }
            }
        },
        confirmButton = {
            Button(
                enabled = DeviceBookRepository.sanitizeTargetForUse(target).isNotBlank(),
                onClick = {
                    val port = portText.toIntOrNull()?.coerceIn(1, 65535) ?: OpenUUConstants.DEFAULT_PORT
                    val cleanTarget = DeviceBookRepository.sanitizeTargetForUse(target)
                    onSave(
                        (initial ?: DeviceBookEntry(
                            id = UUID.randomUUID().toString(),
                            alias = "",
                            target = ""
                        )).copy(
                            alias = alias.trim().ifBlank { cleanTarget },
                            target = cleanTarget,
                            port = port,
                            savedPin = savedPin.trim(),
                            notes = notes.trim(),
                            favorite = favorite
                        )
                    )
                }
            ) {
                Text("保存")
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text("取消")
            }
        }
    )
}

// =========================================================================
// TAB 4: SETTINGS & LOGS (Local Identity, WAN Config, Scrollable Logs)
// =========================================================================

@Composable
private fun SettingsAndLogsTabView(viewModel: OpenUUViewModel) {
    val identity by viewModel.identity.collectAsState()
    val logs by viewModel.logs.collectAsState()

    var coordUrl by remember(identity.wanConfig) { mutableStateOf(identity.wanConfig.coordUrl) }
    var relayUrl by remember(identity.wanConfig) { mutableStateOf(identity.wanConfig.relayUrl) }
    var relayAuthToken by remember(identity.wanConfig) { mutableStateOf(identity.wanConfig.relayAuthToken) }
    var enablePublicFallback by remember(identity.wanConfig) { mutableStateOf(identity.wanConfig.enablePublicFallback) }
    var allowInsecureTls by remember(identity.wanConfig) { mutableStateOf(identity.wanConfig.allowInsecureTls) }
    var savedBanner by remember { mutableStateOf(false) }

    LazyColumn(
        modifier = Modifier
            .fillMaxSize()
            .statusBarsPadding(),
        contentPadding = PaddingValues(16.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp)
    ) {
        item {
            Text(
                text = "设置与日志",
                style = MaterialTheme.typography.headlineSmall
            )
        }

        // Local Device Code & EndpointId Card
        item {
            Card(
                shape = RoundedCornerShape(18.dp),
                border = BorderStroke(1.dp, MaterialTheme.colorScheme.primary.copy(alpha = 0.4f)),
                colors = CardDefaults.cardColors(containerColor = Color.Transparent)
            ) {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .background(
                            Brush.verticalGradient(
                                listOf(
                                    Color(0xFF0F2928),
                                    Color(0xFF151E30)
                                )
                            )
                        )
                        .padding(16.dp),
                    verticalArrangement = Arrangement.spacedBy(10.dp)
                ) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.SpaceBetween
                    ) {
                        Text(
                            text = "本机身份标识",
                            style = MaterialTheme.typography.titleMedium,
                            color = Color.White
                        )
                        IconButton(
                            onClick = { viewModel.refreshIdentityAndDeviceBook() },
                            modifier = Modifier.size(32.dp)
                        ) {
                            Icon(
                                imageVector = Icons.Rounded.Refresh,
                                contentDescription = "刷新身份",
                                tint = MaterialTheme.colorScheme.primary,
                                modifier = Modifier.size(18.dp)
                            )
                        }
                    }

                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.SpaceBetween
                    ) {
                        Column {
                            Text(
                                text = "9 位设备码",
                                style = MaterialTheme.typography.labelSmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                            Text(
                                text = identity.formattedCode.ifBlank { identity.deviceCode.ifBlank { "初始化中..." } },
                                fontSize = 24.sp,
                                fontWeight = FontWeight.Bold,
                                fontFamily = FontFamily.Monospace,
                                color = MaterialTheme.colorScheme.primary
                            )
                        }
                        FilledTonalButton(
                            onClick = {
                                val code = identity.formattedCode.ifBlank { identity.deviceCode }
                                viewModel.copyToLocalClipboard("设备码", code)
                            },
                            enabled = identity.deviceCode.isNotBlank(),
                            shape = RoundedCornerShape(10.dp)
                        ) {
                            Icon(Icons.Rounded.ContentCopy, contentDescription = null, modifier = Modifier.size(15.dp))
                            Spacer(modifier = Modifier.width(4.dp))
                            Text("复制", style = MaterialTheme.typography.labelMedium)
                        }
                    }

                    HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)

                    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Text(
                                text = "EndpointId",
                                style = MaterialTheme.typography.labelSmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                            if (identity.endpointId.isNotBlank()) {
                                TextButton(
                                    onClick = { viewModel.copyToLocalClipboard("EndpointId", identity.endpointId) },
                                    contentPadding = PaddingValues(horizontal = 6.dp, vertical = 0.dp)
                                ) {
                                    Text("复制", style = MaterialTheme.typography.labelSmall)
                                }
                            }
                        }
                        Text(
                            text = identity.endpointId.ifBlank { "-" },
                            style = MaterialTheme.typography.bodySmall,
                            fontFamily = FontFamily.Monospace,
                            color = MaterialTheme.colorScheme.onSurface,
                            maxLines = 2,
                            overflow = TextOverflow.Ellipsis
                        )
                        if (identity.coordStatus.isNotBlank()) {
                            Text(
                                text = "协调服务状态: ${identity.coordStatus}",
                                style = MaterialTheme.typography.labelSmall,
                                color = MaterialTheme.colorScheme.tertiary
                            )
                        }
                    }
                }
            }
        }

        // WAN Configuration Card
        item {
            Card(
                shape = RoundedCornerShape(18.dp),
                colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainer),
                border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant)
            ) {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(16.dp),
                    verticalArrangement = Arrangement.spacedBy(12.dp)
                ) {
                    Text(
                        text = "跨网中继与协调服务 (WAN)",
                        style = MaterialTheme.typography.titleMedium
                    )

                    OutlinedTextField(
                        value = coordUrl,
                        onValueChange = { coordUrl = it; savedBanner = false },
                        label = { Text("coord_url（设备码协调服务）") },
                        singleLine = true,
                        shape = RoundedCornerShape(12.dp),
                        modifier = Modifier.fillMaxWidth()
                    )

                    OutlinedTextField(
                        value = relayUrl,
                        onValueChange = { relayUrl = it; savedBanner = false },
                        label = { Text("relay_url（自建中继节点）") },
                        singleLine = true,
                        shape = RoundedCornerShape(12.dp),
                        modifier = Modifier.fillMaxWidth()
                    )

                    OutlinedTextField(
                        value = relayAuthToken,
                        onValueChange = { relayAuthToken = it; savedBanner = false },
                        label = { Text("relay_auth_token（鉴权令牌，可选）") },
                        singleLine = true,
                        shape = RoundedCornerShape(12.dp),
                        modifier = Modifier.fillMaxWidth()
                    )

                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.SpaceBetween
                    ) {
                        Column(modifier = Modifier.weight(1f)) {
                            Text("enable_public_fallback", style = MaterialTheme.typography.bodyMedium)
                            Text(
                                "自建中继不可达时自动回退公共中继",
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                        }
                        Switch(
                            checked = enablePublicFallback,
                            onCheckedChange = { enablePublicFallback = it; savedBanner = false }
                        )
                    }

                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.SpaceBetween
                    ) {
                        Column(modifier = Modifier.weight(1f)) {
                            Text("allow_insecure_tls", style = MaterialTheme.typography.bodyMedium)
                            Text(
                                "允许自签名 HTTPS 证书（内网测试用）",
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                        }
                        Switch(
                            checked = allowInsecureTls,
                            onCheckedChange = { allowInsecureTls = it; savedBanner = false }
                        )
                    }

                    Button(
                        onClick = {
                            viewModel.saveWanConfig(
                                WanConfig(
                                    coordUrl = coordUrl.trim(),
                                    relayUrl = relayUrl.trim(),
                                    relayAuthToken = relayAuthToken.trim(),
                                    enablePublicFallback = enablePublicFallback,
                                    allowInsecureTls = allowInsecureTls
                                )
                            )
                            savedBanner = true
                        },
                        shape = RoundedCornerShape(12.dp),
                        modifier = Modifier.fillMaxWidth()
                    ) {
                        Icon(
                            imageVector = if (savedBanner) Icons.Rounded.Check else Icons.Rounded.Save,
                            contentDescription = null,
                            modifier = Modifier.size(18.dp)
                        )
                        Spacer(modifier = Modifier.width(6.dp))
                        Text(if (savedBanner) "已保存 WAN 配置" else "保存 WAN 配置")
                    }
                }
            }
        }

        // Self-Host AI Deployment Prompt Card
        item {
            val context = LocalContext.current
            val uriHandler = LocalUriHandler.current
            var promptCopied by remember { mutableStateOf(false) }
            val githubRepoUrl = "https://github.com/onekb/OpenUU"
            val selfHostAiPrompt = remember {
                """
                请帮我部署一套私有的 OpenUU 跨网寻址（Coord）与打洞中继（Relay）服务器。
                开源仓库地址：https://github.com/onekb/OpenUU （请先拉取或阅读仓库下的 deploy/ 目录与 README.md）。

                部署要求：
                1. 云服务器方案请参考 `deploy/docker-compose.yml`、`deploy/Dockerfile.coord` 与 `deploy/Caddyfile`；零暴露公网 IP 方案请参考 `deploy/cloudflare-worker` 与 `deploy/cloudflare-relay-worker`（Cloudflare Workers + D1 + Tunnel）。
                2. 先向我确认服务器 SSH 信息与解析好的 Coord / Relay 二级域名（或是否采用纯 IP 自签证书 / Cloudflare 方案）。
                3. 自动完成容器构建启动、HTTPS 证书签发、端口放行（TCP 80/443，UDP 443/3478/7842）及中继鉴权 Bearer Token 配置，并验证 `/health` 接口返回正常。
                4. 部署完成后，直接输出需要填入 OpenUU「网络与日志」页面的三项配置：设备码寻址 (Coord URL)、打洞与中继 (Relay URL)、中继鉴权 Token。
                """.trimIndent()
            }

            fun copyPromptAndOpenGitHub(openWeb: Boolean) {
                val cm = context.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
                cm?.setPrimaryClip(ClipData.newPlainText("OpenUU Self-Host Prompt", selfHostAiPrompt))
                promptCopied = true
                if (openWeb) {
                    runCatching { uriHandler.openUri(githubRepoUrl) }
                }
            }

            Card(
                shape = RoundedCornerShape(18.dp),
                colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainer),
                border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant)
            ) {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(16.dp),
                    verticalArrangement = Arrangement.spacedBy(10.dp)
                ) {
                    Text(
                        text = "自建专属机房 · AI 自动部署提示词",
                        style = MaterialTheme.typography.titleMedium
                    )
                    Text(
                        text = "想独享满速带宽？点击下方提示词卡片即可自动复制并打开 GitHub 仓库，把提示词直接发给你的 AI 助手即可自动部署专属服务器：",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                    Surface(
                        shape = RoundedCornerShape(12.dp),
                        color = MaterialTheme.colorScheme.surfaceContainerLow,
                        border = BorderStroke(1.dp, MaterialTheme.colorScheme.primary.copy(alpha = 0.35f)),
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(12.dp))
                            .clickable { copyPromptAndOpenGitHub(openWeb = true) }
                    ) {
                        Text(
                            text = selfHostAiPrompt,
                            fontFamily = FontFamily.Monospace,
                            fontSize = 11.5.sp,
                            lineHeight = 17.sp,
                            color = MaterialTheme.colorScheme.onSurface,
                            modifier = Modifier.padding(12.dp)
                        )
                    }
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.spacedBy(10.dp)
                    ) {
                        OutlinedButton(
                            onClick = { copyPromptAndOpenGitHub(openWeb = false) },
                            shape = RoundedCornerShape(12.dp),
                            modifier = Modifier.weight(1f)
                        ) {
                            Icon(Icons.Rounded.ContentCopy, contentDescription = null, modifier = Modifier.size(16.dp))
                            Spacer(modifier = Modifier.width(6.dp))
                            Text(if (promptCopied) "已复制" else "仅复制提示词")
                        }
                        Button(
                            onClick = { copyPromptAndOpenGitHub(openWeb = true) },
                            shape = RoundedCornerShape(12.dp),
                            modifier = Modifier.weight(1.3f)
                        ) {
                            Icon(Icons.Rounded.Public, contentDescription = null, modifier = Modifier.size(16.dp))
                            Spacer(modifier = Modifier.width(6.dp))
                            Text("复制并打开 GitHub")
                        }
                    }
                }
            }
        }

        // Live Logs Section
        item {
            Card(
                shape = RoundedCornerShape(18.dp),
                colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainer),
                border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant)
            ) {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(14.dp),
                    verticalArrangement = Arrangement.spacedBy(10.dp)
                ) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.SpaceBetween
                    ) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(6.dp)
                        ) {
                            Icon(
                                imageVector = Icons.Rounded.Terminal,
                                contentDescription = null,
                                tint = MaterialTheme.colorScheme.primary,
                                modifier = Modifier.size(18.dp)
                            )
                            Text(
                                text = "运行日志 (${logs.size})",
                                style = MaterialTheme.typography.titleMedium
                            )
                        }
                        Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                            TextButton(
                                onClick = {
                                    viewModel.copyToLocalClipboard("运行日志", logs.joinToString("\n"))
                                },
                                enabled = logs.isNotEmpty()
                            ) {
                                Text("复制", style = MaterialTheme.typography.labelMedium)
                            }
                            TextButton(
                                onClick = { viewModel.clearLogs() },
                                enabled = logs.isNotEmpty()
                            ) {
                                Text("清空", style = MaterialTheme.typography.labelMedium)
                            }
                        }
                    }

                    Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .heightIn(min = 180.dp, max = 320.dp)
                            .clip(RoundedCornerShape(12.dp))
                            .background(Color(0xFF070A12))
                            .padding(10.dp)
                    ) {
                        if (logs.isEmpty()) {
                            Text(
                                text = "暂无日志输出",
                                style = MaterialTheme.typography.bodySmall,
                                fontFamily = FontFamily.Monospace,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                        } else {
                            Column(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .verticalScroll(rememberScrollState()),
                                verticalArrangement = Arrangement.spacedBy(3.dp)
                            ) {
                                logs.asReversed().forEach { line ->
                                    Text(
                                        text = line,
                                        fontSize = 11.sp,
                                        lineHeight = 15.sp,
                                        fontFamily = FontFamily.Monospace,
                                        color = when {
                                            line.contains("ERROR", ignoreCase = true) || line.contains("失败") -> Color(0xFFFB7185)
                                            line.contains("connected", ignoreCase = true) || line.contains("已就绪") -> Color(0xFF34D399)
                                            else -> Color(0xFFCBD5E1)
                                        }
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun SectionTitleRow(
    icon: ImageVector,
    title: String,
    trailingText: String
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 2.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.SpaceBetween
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp)
        ) {
            Icon(
                imageVector = icon,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.primary,
                modifier = Modifier.size(18.dp)
            )
            Text(
                text = title,
                style = MaterialTheme.typography.titleSmall,
                color = MaterialTheme.colorScheme.onBackground
            )
        }
        Text(
            text = trailingText,
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
    }
}

private fun formatTargetTextFieldValue(
    input: TextFieldValue,
    previousText: String
): TextFieldValue {
    if (input.composition != null) return input

    var raw = input.text
    var cursor = input.selection.end.coerceIn(0, raw.length)

    if (DeviceBookRepository.isDeviceCodeLike(previousText) &&
        DeviceBookRepository.isDeviceCodeLike(raw) &&
        raw.length == previousText.length - 1 &&
        cursor in 1 until previousText.length &&
        previousText[cursor] == ' '
    ) {
        val prevDigits = previousText.filter { it in '0'..'9' }
        val rawDigits = raw.filter { it in '0'..'9' }
        if (prevDigits == rawDigits) {
            raw = raw.removeRange(cursor - 1, cursor)
            cursor -= 1
        }
    }

    val formatted = DeviceBookRepository.formatTargetInput(raw)
    if (formatted.isEmpty()) {
        return TextFieldValue("", selection = TextRange(0))
    }

    val prefix = raw.substring(0, cursor.coerceAtMost(raw.length))
    val newCursor = if (DeviceBookRepository.isDeviceCodeLike(formatted)) {
        val digitsBefore = prefix.count { it in '0'..'9' }
        if (digitsBefore == 0) {
            0
        } else {
            var seen = 0
            var pos = formatted.length
            for (i in formatted.indices) {
                if (formatted[i] in '0'..'9') {
                    seen++
                    if (seen == digitsBefore) {
                        pos = i + 1
                        break
                    }
                }
            }
            pos
        }
    } else {
        val nonSpaceBefore = prefix.count { !it.isWhitespace() }
        if (nonSpaceBefore == 0) {
            0
        } else {
            var seen = 0
            var pos = formatted.length
            for (i in formatted.indices) {
                if (!formatted[i].isWhitespace()) {
                    seen++
                    if (seen == nonSpaceBefore) {
                        pos = i + 1
                        break
                    }
                }
            }
            pos
        }
    }

    return TextFieldValue(
        text = formatted,
        selection = TextRange(newCursor.coerceIn(0, formatted.length))
    )
}
