package ren.onekb.openuu

import android.app.Activity
import android.widget.Toast
import androidx.activity.compose.BackHandler
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
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.ContentCopy
import androidx.compose.material.icons.rounded.ErrorOutline
import androidx.compose.material.icons.rounded.MoreHoriz
import androidx.compose.material.icons.rounded.Notifications
import androidx.compose.material.icons.rounded.Refresh
import androidx.compose.material.icons.rounded.Star
import androidx.compose.material.icons.rounded.Tune
import androidx.compose.material.icons.rounded.Visibility
import androidx.compose.material.icons.rounded.VisibilityOff
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.delay
import java.util.UUID

private val BgObsidian = Color(0xFF09090B)
private val SurfaceCard = Color(0xFF121215)
private val SurfaceElevated = Color(0xFF16161A)
private val SurfaceInput = Color(0xFF1A1A20)
private val BorderHairline = Color(0xFF27272E)
private val DividerHairline = Color(0xFF232329)
private val TextPrimary = Color(0xFFF4F4F6)
private val TextSecondary = Color(0xFF8E8E98)
private val TextMuted = Color(0xFF63636E)
private val StatusOnline = Color(0xFF30D158)
private val StatusOffline = Color(0xFF52525B)
private val StatusDanger = Color(0xFFFF453A)

private data class HostRowItem(
    val key: String,
    val name: String,
    val subtitle: String,
    val isOnline: Boolean,
    val isTrusted: Boolean,
    val isFavorite: Boolean,
    val savedPin: String,
    val bookEntry: DeviceBookEntry?,
    val trustedPeer: TrustedPeer?,
    val lanPeer: DiscoveredPeer?,
    val connectAction: (String) -> Unit
)

@Composable
fun MainScreen(
    viewModel: OpenUUViewModel,
    isImmersiveFullscreen: Boolean = false,
    isLandscape: Boolean = false,
    onPickFile: () -> Unit
) {
    val selectedTab by viewModel.selectedTab.collectAsState()
    val connectionPhase by viewModel.connectionPhase.collectAsState()
    val notificationBanner by viewModel.notificationBanner.collectAsState()

    val showRemote = selectedTab == MainTab.REMOTE && connectionPhase.isConnected

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(if (isImmersiveFullscreen) Color.Black else BgObsidian)
    ) {
        if (showRemote) {
            RemoteWorkspaceView(
                viewModel = viewModel,
                isImmersiveFullscreen = isImmersiveFullscreen,
                isLandscape = isLandscape,
                onPickFile = onPickFile
            )
        } else {
            HostsHomeScreen(viewModel = viewModel)
        }

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
                RemoteNotificationCard(
                    banner = banner,
                    onClick = {
                        viewModel.dismissNotificationBanner()
                        if (connectionPhase.isConnected) {
                            viewModel.enterRemoteWorkspace()
                        }
                    },
                    onDismiss = { viewModel.dismissNotificationBanner() }
                )
            }
        }
    }
}

@Composable
private fun RemoteNotificationCard(
    banner: RemoteNotificationBanner,
    onClick: () -> Unit,
    onDismiss: () -> Unit
) {
    Surface(
        onClick = onClick,
        shape = RoundedCornerShape(10.dp),
        color = SurfaceElevated,
        border = BorderStroke(0.5.dp, BorderHairline),
        shadowElevation = 6.dp,
        modifier = Modifier.fillMaxWidth()
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp)
        ) {
            Icon(
                imageVector = Icons.Rounded.Notifications,
                contentDescription = null,
                tint = TextPrimary,
                modifier = Modifier.size(18.dp)
            )
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = banner.title,
                    style = MaterialTheme.typography.titleSmall,
                    color = TextPrimary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )
                val detail = listOf(banner.subtitle, banner.body).filter { it.isNotBlank() }.joinToString(" · ")
                if (detail.isNotEmpty()) {
                    Text(
                        text = detail,
                        style = MaterialTheme.typography.bodySmall,
                        color = TextSecondary,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis
                    )
                }
            }
            IconButton(onClick = onDismiss, modifier = Modifier.size(26.dp)) {
                Icon(
                    imageVector = Icons.Rounded.Close,
                    contentDescription = "关闭通知",
                    tint = TextSecondary,
                    modifier = Modifier.size(16.dp)
                )
            }
        }
    }
}

@Composable
private fun HostsHomeScreen(viewModel: OpenUUViewModel) {
    val context = LocalContext.current
    val connectionPhase by viewModel.connectionPhase.collectAsState()
    val linkBadge by viewModel.linkBadge.collectAsState()
    val discoveredPeers by viewModel.discoveredPeers.collectAsState()
    val identity by viewModel.identity.collectAsState()
    val deviceBook by viewModel.deviceBook.collectAsState()
    val probeResults by viewModel.probeResults.collectAsState()
    val releaseInfo by viewModel.updater.releaseInfo.collectAsState()
    val showUpdateDialog by viewModel.updater.showUpdateDialog.collectAsState()

    var showSettingsSheet by remember { mutableStateOf(false) }
    var editingEntry by remember { mutableStateOf<DeviceBookEntry?>(null) }
    var showEditDialog by remember { mutableStateOf(false) }
    var pinPromptHost by remember { mutableStateOf<HostRowItem?>(null) }
    var copiedLocalCode by remember { mutableStateOf(false) }
    var lastRootBackPressMs by remember { mutableLongStateOf(0L) }

    var targetField by remember { mutableStateOf(TextFieldValue("")) }
    var manualPin by remember { mutableStateOf("") }
    var showManualPin by remember { mutableStateOf(false) }

    BackHandler(enabled = true) {
        when {
            pinPromptHost != null -> pinPromptHost = null
            showEditDialog -> showEditDialog = false
            showSettingsSheet -> showSettingsSheet = false
            connectionPhase is ConnectionPhase.Connecting -> viewModel.disconnect()
            else -> {
                val now = System.currentTimeMillis()
                if (now - lastRootBackPressMs <= 2000L) {
                    (context as? Activity)?.moveTaskToBack(true)
                } else {
                    lastRootBackPressMs = now
                    Toast.makeText(context, "再按一次返回退到后台", Toast.LENGTH_SHORT).show()
                }
            }
        }
    }

    LaunchedEffect(Unit) {
        viewModel.probeDeviceBookOnline()
    }

    LaunchedEffect(copiedLocalCode) {
        if (copiedLocalCode) {
            delay(1400L)
            copiedLocalCode = false
        }
    }

    val hostRows = remember(discoveredPeers, deviceBook, identity.trustedPeers, probeResults) {
        buildUnifiedHostRows(
            lanPeers = discoveredPeers,
            deviceBook = deviceBook,
            trustedPeers = identity.trustedPeers,
            probeResults = probeResults,
            viewModel = viewModel
        )
    }

    LazyColumn(
        modifier = Modifier
            .fillMaxSize()
            .statusBarsPadding()
            .navigationBarsPadding()
            .imePadding(),
        contentPadding = PaddingValues(horizontal = 16.dp, vertical = 14.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp)
    ) {
        // 1. Industrial Top Bar
        item {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.SpaceBetween
            ) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(9.dp)
                ) {
                    Image(
                        painter = painterResource(id = R.drawable.openuu_brand_icon),
                        contentDescription = "OpenUU",
                        contentScale = ContentScale.Fit,
                        modifier = Modifier
                            .size(28.dp)
                            .clip(RoundedCornerShape(7.dp))
                    )
                    Column {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(5.dp)
                        ) {
                            Text(
                                text = "OpenUU",
                                fontSize = 18.sp,
                                fontWeight = FontWeight.SemiBold,
                                letterSpacing = (-0.4).sp,
                                color = TextPrimary
                            )
                            Text(
                                text = AppUpdater.displayVersion,
                                fontFamily = FontFamily.Monospace,
                                fontSize = 10.5.sp,
                                color = TextMuted
                            )
                        }
                        if (releaseInfo?.hasUpdate == true) {
                            Text(
                                text = "⬆ 新版本 ${releaseInfo!!.tagName} · 点击更新",
                                fontSize = 10.5.sp,
                                fontWeight = FontWeight.SemiBold,
                                color = Color(0xFFFF9F0A),
                                modifier = Modifier.clickable {
                                    viewModel.updater.setShowUpdateDialog(true)
                                }
                            )
                        }
                    }
                }

                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    val codeText = identity.formattedCode.ifBlank { identity.deviceCode }
                    if (codeText.isNotBlank()) {
                        Surface(
                            onClick = {
                                viewModel.copyToLocalClipboard("本机设备码", codeText)
                                copiedLocalCode = true
                            },
                            color = SurfaceElevated,
                            shape = RoundedCornerShape(8.dp),
                            border = BorderStroke(0.5.dp, BorderHairline)
                        ) {
                            Text(
                                text = if (copiedLocalCode) "已复制 $codeText" else "本机 $codeText",
                                fontFamily = FontFamily.Monospace,
                                fontSize = 11.5.sp,
                                color = if (copiedLocalCode) StatusOnline else TextPrimary,
                                modifier = Modifier.padding(horizontal = 9.dp, vertical = 6.dp)
                            )
                        }
                    }

                    Surface(
                        onClick = { showSettingsSheet = true },
                        color = SurfaceElevated,
                        shape = RoundedCornerShape(8.dp),
                        border = BorderStroke(0.5.dp, BorderHairline)
                    ) {
                        Box(
                            modifier = Modifier.size(32.dp),
                            contentAlignment = Alignment.Center
                        ) {
                            Icon(
                                imageVector = Icons.Rounded.Tune,
                                contentDescription = "设置与日志",
                                tint = TextPrimary,
                                modifier = Modifier.size(17.dp)
                            )
                        }
                    }
                }
            }
        }

        // 2. Active Session / Connecting / Error Banner
        if (connectionPhase !is ConnectionPhase.Idle) {
            item {
                SessionStatusBanner(
                    phase = connectionPhase,
                    linkBadge = linkBadge,
                    onEnterRemote = { viewModel.enterRemoteWorkspace() },
                    onDisconnect = { viewModel.disconnect() },
                    onDismissError = { viewModel.clearConnectionError() }
                )
            }
        }

        // 3. Available Hosts Unified Grouped List
        item {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.SpaceBetween
                ) {
                    Text(
                        text = "可用主机",
                        style = MaterialTheme.typography.labelMedium,
                        color = TextSecondary,
                        modifier = Modifier.padding(start = 2.dp)
                    )
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(4.dp)
                    ) {
                        IconButton(
                            onClick = { viewModel.probeDeviceBookOnline() },
                            modifier = Modifier.size(28.dp)
                        ) {
                            Icon(
                                imageVector = Icons.Rounded.Refresh,
                                contentDescription = "探测在线状态",
                                tint = TextSecondary,
                                modifier = Modifier.size(16.dp)
                            )
                        }
                        Surface(
                            onClick = {
                                editingEntry = null
                                showEditDialog = true
                            },
                            color = SurfaceElevated,
                            shape = RoundedCornerShape(7.dp),
                            border = BorderStroke(0.5.dp, BorderHairline)
                        ) {
                            Row(
                                modifier = Modifier.padding(horizontal = 8.dp, vertical = 4.dp),
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(3.dp)
                            ) {
                                Icon(
                                    imageVector = Icons.Rounded.Add,
                                    contentDescription = null,
                                    tint = TextPrimary,
                                    modifier = Modifier.size(13.dp)
                                )
                                Text(
                                    text = "添加",
                                    fontSize = 12.sp,
                                    fontWeight = FontWeight.Medium,
                                    color = TextPrimary
                                )
                            }
                        }
                    }
                }

                Surface(
                    color = SurfaceCard,
                    shape = RoundedCornerShape(12.dp),
                    border = BorderStroke(0.5.dp, BorderHairline),
                    modifier = Modifier.fillMaxWidth()
                ) {
                    if (hostRows.isEmpty()) {
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(horizontal = 14.dp, vertical = 18.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(10.dp)
                        ) {
                            CircularProgressIndicator(
                                modifier = Modifier.size(15.dp),
                                strokeWidth = 1.6.dp,
                                color = TextSecondary
                            )
                            Text(
                                text = "正在扫描局域网 Mac，或点击右上角添加常用主机",
                                style = MaterialTheme.typography.bodySmall,
                                color = TextSecondary
                            )
                        }
                    } else {
                        Column(modifier = Modifier.fillMaxWidth()) {
                            hostRows.forEachIndexed { idx, row ->
                                HostListRow(
                                    item = row,
                                    onTap = {
                                        if (row.isTrusted || row.savedPin.isNotBlank()) {
                                            row.connectAction(if (row.isTrusted) "" else row.savedPin)
                                        } else {
                                            pinPromptHost = row
                                        }
                                    },
                                    onToggleFavorite = row.bookEntry?.let { entry ->
                                        { viewModel.toggleDeviceFavorite(entry.id) }
                                    },
                                    onEdit = row.bookEntry?.let { entry ->
                                        {
                                            editingEntry = entry
                                            showEditDialog = true
                                        }
                                    },
                                    onSaveLanPeer = if (row.bookEntry == null && row.lanPeer != null) {
                                        {
                                            val lp = row.lanPeer
                                            val tgt = lp.deviceCode.takeIf { it.length == 9 } ?: lp.primaryAddress
                                            viewModel.upsertDeviceBookEntry(
                                                DeviceBookEntry(
                                                    id = UUID.randomUUID().toString(),
                                                    alias = lp.deviceName,
                                                    target = tgt,
                                                    port = lp.port,
                                                    remoteDeviceId = lp.deviceId,
                                                    deviceCode = lp.deviceCode
                                                )
                                            )
                                        }
                                    } else {
                                        null
                                    },
                                    onRevokeTrust = row.trustedPeer?.let { tp ->
                                        { viewModel.removeTrustedPeer(tp.deviceId) }
                                    },
                                    onDelete = row.bookEntry?.let { entry ->
                                        { viewModel.deleteDeviceBookEntry(entry.id) }
                                    }
                                )
                                if (idx < hostRows.lastIndex) {
                                    HorizontalDivider(
                                        thickness = 0.5.dp,
                                        color = DividerHairline,
                                        modifier = Modifier.padding(start = 32.dp)
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }

        // 4. Manual Connect Card
        item {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(
                    text = "手动连接",
                    style = MaterialTheme.typography.labelMedium,
                    color = TextSecondary,
                    modifier = Modifier.padding(start = 2.dp)
                )

                Surface(
                    color = SurfaceCard,
                    shape = RoundedCornerShape(12.dp),
                    border = BorderStroke(0.5.dp, BorderHairline),
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(12.dp),
                        verticalArrangement = Arrangement.spacedBy(10.dp)
                    ) {
                        OutlinedTextField(
                            value = targetField,
                            onValueChange = { targetField = formatTargetTextFieldValue(it, targetField.text) },
                            placeholder = {
                                Text(
                                    text = "9 位设备码 / IP:Port / openuu://",
                                    style = MaterialTheme.typography.bodySmall,
                                    color = TextMuted
                                )
                            },
                            singleLine = true,
                            shape = RoundedCornerShape(9.dp),
                            modifier = Modifier.fillMaxWidth(),
                            trailingIcon = {
                                Row(
                                    verticalAlignment = Alignment.CenterVertically,
                                    modifier = Modifier.padding(end = 6.dp)
                                ) {
                                    if (targetField.text.isNotEmpty()) {
                                        IconButton(
                                            onClick = { targetField = TextFieldValue("") },
                                            modifier = Modifier.size(28.dp)
                                        ) {
                                            Icon(
                                                imageVector = Icons.Rounded.Close,
                                                contentDescription = "清除",
                                                tint = TextSecondary,
                                                modifier = Modifier.size(16.dp)
                                            )
                                        }
                                    }
                                    TextButton(
                                        onClick = {
                                            val pasted = DeviceBookRepository.formatTargetInput(
                                                viewModel.readLocalClipboardText().trim()
                                            )
                                            if (pasted.isNotEmpty()) {
                                                targetField = TextFieldValue(pasted, TextRange(pasted.length))
                                            }
                                        },
                                        contentPadding = PaddingValues(horizontal = 8.dp, vertical = 2.dp)
                                    ) {
                                        Text(
                                            text = "粘贴",
                                            fontSize = 12.sp,
                                            fontWeight = FontWeight.Medium,
                                            color = TextPrimary
                                        )
                                    }
                                }
                            },
                            colors = industrialTextFieldColors()
                        )

                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(8.dp)
                        ) {
                            OutlinedTextField(
                                value = manualPin,
                                onValueChange = { manualPin = it },
                                placeholder = {
                                    Text(
                                        text = "配对码（已信任可留空）",
                                        style = MaterialTheme.typography.bodySmall,
                                        color = TextMuted
                                    )
                                },
                                singleLine = true,
                                visualTransformation = if (showManualPin) VisualTransformation.None else PasswordVisualTransformation(),
                                trailingIcon = {
                                    IconButton(
                                        onClick = { showManualPin = !showManualPin },
                                        modifier = Modifier.size(32.dp)
                                    ) {
                                        Icon(
                                            imageVector = if (showManualPin) Icons.Rounded.VisibilityOff else Icons.Rounded.Visibility,
                                            contentDescription = if (showManualPin) "隐藏密码" else "显示密码",
                                            tint = TextSecondary,
                                            modifier = Modifier.size(18.dp)
                                        )
                                    }
                                },
                                shape = RoundedCornerShape(9.dp),
                                keyboardOptions = KeyboardOptions(
                                    keyboardType = KeyboardType.Password,
                                    imeAction = ImeAction.Go
                                ),
                                keyboardActions = KeyboardActions(
                                    onGo = {
                                        if (targetField.text.isNotBlank() && !connectionPhase.isConnecting) {
                                            viewModel.connectSmart(targetField.text, OpenUUConstants.DEFAULT_PORT, manualPin)
                                        }
                                    }
                                ),
                                modifier = Modifier.weight(1f),
                                colors = industrialTextFieldColors()
                            )

                            Button(
                                onClick = {
                                    viewModel.connectSmart(
                                        target = targetField.text,
                                        defaultPort = OpenUUConstants.DEFAULT_PORT,
                                        pin = manualPin
                                    )
                                },
                                enabled = targetField.text.isNotBlank() && !connectionPhase.isConnecting,
                                shape = RoundedCornerShape(9.dp),
                                colors = ButtonDefaults.buttonColors(
                                    containerColor = TextPrimary,
                                    contentColor = BgObsidian,
                                    disabledContainerColor = Color(0xFF27272F),
                                    disabledContentColor = TextMuted
                                ),
                                contentPadding = PaddingValues(horizontal = 18.dp, vertical = 14.dp)
                            ) {
                                Text(
                                    if (connectionPhase.isConnecting) "连接中..." else "连接",
                                    fontWeight = FontWeight.SemiBold,
                                    fontSize = 14.sp
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    pinPromptHost?.let { host ->
        PinPromptDialog(
            hostName = host.name,
            onDismiss = { pinPromptHost = null },
            onConfirm = { enteredPin ->
                pinPromptHost = null
                host.connectAction(enteredPin)
            }
        )
    }

    if (showEditDialog) {
        DeviceBookEditDialog(
            initial = editingEntry,
            onDismiss = { showEditDialog = false },
            onSave = { updated ->
                viewModel.upsertDeviceBookEntry(updated)
                showEditDialog = false
            }
        )
    }

    if (showSettingsSheet) {
        SettingsAndLogsSheet(
            viewModel = viewModel,
            onDismiss = { showSettingsSheet = false }
        )
    }

    if (showUpdateDialog) {
        SoftwareUpdateDialog(
            updater = viewModel.updater,
            onDismiss = { viewModel.updater.setShowUpdateDialog(false) }
        )
    }
}

@Composable
private fun SessionStatusBanner(
    phase: ConnectionPhase,
    linkBadge: String,
    onEnterRemote: () -> Unit,
    onDisconnect: () -> Unit,
    onDismissError: () -> Unit
) {
    val isError = phase is ConnectionPhase.Error
    Surface(
        color = if (isError) Color(0xFF1F1214) else SurfaceElevated,
        shape = RoundedCornerShape(10.dp),
        border = BorderStroke(0.5.dp, if (isError) Color(0xFF4C1D24) else BorderHairline),
        modifier = Modifier.fillMaxWidth()
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 12.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp)
        ) {
            when (phase) {
                is ConnectionPhase.Connected -> {
                    Box(
                        modifier = Modifier
                            .size(8.dp)
                            .clip(CircleShape)
                            .background(StatusOnline)
                    )
                    Column(modifier = Modifier.weight(1f)) {
                        Text(
                            text = "正在远控 ${phase.hostName}",
                            style = MaterialTheme.typography.titleSmall,
                            color = TextPrimary,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis
                        )
                        if (linkBadge.isNotBlank()) {
                            Text(
                                text = linkBadge,
                                fontFamily = FontFamily.Monospace,
                                fontSize = 11.sp,
                                color = TextSecondary,
                                maxLines = 1
                            )
                        }
                    }
                    Button(
                        onClick = onEnterRemote,
                        shape = RoundedCornerShape(8.dp),
                        colors = ButtonDefaults.buttonColors(
                            containerColor = TextPrimary,
                            contentColor = BgObsidian
                        ),
                        contentPadding = PaddingValues(horizontal = 11.dp, vertical = 6.dp)
                    ) {
                        Text("进入画面", fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
                    }
                    OutlinedButton(
                        onClick = onDisconnect,
                        shape = RoundedCornerShape(8.dp),
                        border = BorderStroke(0.5.dp, BorderHairline),
                        colors = ButtonDefaults.outlinedButtonColors(contentColor = TextSecondary),
                        contentPadding = PaddingValues(horizontal = 10.dp, vertical = 6.dp)
                    ) {
                        Text("断开", fontSize = 12.sp)
                    }
                }

                is ConnectionPhase.Connecting -> {
                    var elapsedSec by remember { mutableStateOf(0) }
                    LaunchedEffect(Unit) {
                        elapsedSec = 0
                        while (true) {
                            delay(1000L)
                            elapsedSec += 1
                        }
                    }

                    CircularProgressIndicator(
                        modifier = Modifier.size(16.dp),
                        strokeWidth = 1.8.dp,
                        color = Color(0xFFFF9F0A)
                    )
                    Column(
                        modifier = Modifier.weight(1f),
                        verticalArrangement = Arrangement.spacedBy(2.dp)
                    ) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(6.dp)
                        ) {
                            Text(
                                text = "正在建立连接",
                                fontSize = 11.5.sp,
                                fontWeight = FontWeight.SemiBold,
                                color = Color(0xFFFF9F0A)
                            )
                            if (elapsedSec > 0) {
                                Text(
                                    text = "已等待 ${elapsedSec}s",
                                    fontFamily = FontFamily.Monospace,
                                    fontSize = 11.sp,
                                    color = TextSecondary
                                )
                            }
                        }
                        Text(
                            text = phase.detail,
                            style = MaterialTheme.typography.bodySmall,
                            color = TextPrimary,
                            maxLines = 3,
                            overflow = TextOverflow.Ellipsis
                        )
                    }
                    TextButton(
                        onClick = onDisconnect,
                        contentPadding = PaddingValues(horizontal = 8.dp, vertical = 4.dp)
                    ) {
                        Text("取消", fontSize = 12.sp, color = TextSecondary)
                    }
                }

                is ConnectionPhase.Error -> {
                    Icon(
                        imageVector = Icons.Rounded.ErrorOutline,
                        contentDescription = null,
                        tint = StatusDanger,
                        modifier = Modifier.size(18.dp)
                    )
                    Text(
                        text = phase.reason,
                        style = MaterialTheme.typography.bodySmall,
                        color = Color(0xFFFF8A80),
                        modifier = Modifier.weight(1f)
                    )
                    IconButton(onClick = onDismissError, modifier = Modifier.size(26.dp)) {
                        Icon(
                            imageVector = Icons.Rounded.Close,
                            contentDescription = "忽略",
                            tint = TextSecondary,
                            modifier = Modifier.size(15.dp)
                        )
                    }
                }

                ConnectionPhase.Idle -> Unit
            }
        }
    }
}

@Composable
private fun HostListRow(
    item: HostRowItem,
    onTap: () -> Unit,
    onToggleFavorite: (() -> Unit)?,
    onEdit: (() -> Unit)?,
    onSaveLanPeer: (() -> Unit)?,
    onRevokeTrust: (() -> Unit)?,
    onDelete: (() -> Unit)?
) {
    var menuExpanded by remember { mutableStateOf(false) }
    val hasMenu = onEdit != null || onRevokeTrust != null || onDelete != null || onSaveLanPeer != null

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onTap)
            .padding(start = 14.dp, end = 6.dp, top = 12.dp, bottom = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp)
    ) {
        Box(
            modifier = Modifier
                .size(7.dp)
                .clip(CircleShape)
                .background(if (item.isOnline) StatusOnline else StatusOffline)
        )

        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(5.dp)
            ) {
                Text(
                    text = item.name,
                    style = MaterialTheme.typography.titleSmall,
                    color = TextPrimary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f, fill = false)
                )
                if (item.isFavorite) {
                    Icon(
                        imageVector = Icons.Rounded.Star,
                        contentDescription = null,
                        tint = Color(0xFFA1A1AA),
                        modifier = Modifier.size(13.dp)
                    )
                }
            }
            Text(
                text = item.subtitle,
                fontFamily = FontFamily.Monospace,
                fontSize = 11.5.sp,
                color = TextSecondary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis
            )
        }

        if (hasMenu) {
            Box {
                IconButton(
                    onClick = { menuExpanded = true },
                    modifier = Modifier.size(34.dp)
                ) {
                    Icon(
                        imageVector = Icons.Rounded.MoreHoriz,
                        contentDescription = "更多操作",
                        tint = TextSecondary,
                        modifier = Modifier.size(18.dp)
                    )
                }
                DropdownMenu(
                    expanded = menuExpanded,
                    onDismissRequest = { menuExpanded = false },
                    containerColor = SurfaceElevated
                ) {
                    onToggleFavorite?.let { action ->
                        DropdownMenuItem(
                            text = { Text(if (item.isFavorite) "取消置顶" else "置顶主机", color = TextPrimary) },
                            onClick = { menuExpanded = false; action() }
                        )
                    }
                    onEdit?.let { action ->
                        DropdownMenuItem(
                            text = { Text("编辑主机", color = TextPrimary) },
                            onClick = { menuExpanded = false; action() }
                        )
                    }
                    onSaveLanPeer?.let { action ->
                        DropdownMenuItem(
                            text = { Text("保存到主机列表", color = TextPrimary) },
                            onClick = { menuExpanded = false; action() }
                        )
                    }
                    onRevokeTrust?.let { action ->
                        DropdownMenuItem(
                            text = { Text("撤销免密信任", color = StatusDanger) },
                            onClick = { menuExpanded = false; action() }
                        )
                    }
                    onDelete?.let { action ->
                        DropdownMenuItem(
                            text = { Text("删除主机", color = StatusDanger) },
                            onClick = { menuExpanded = false; action() }
                        )
                    }
                }
            }
        }
    }
}

private fun buildUnifiedHostRows(
    lanPeers: List<DiscoveredPeer>,
    deviceBook: List<DeviceBookEntry>,
    trustedPeers: List<TrustedPeer>,
    probeResults: Map<String, DeviceProbeResult>,
    viewModel: OpenUUViewModel
): List<HostRowItem> {
    val rows = mutableListOf<HostRowItem>()
    val consumedBookIds = mutableSetOf<String>()
    val consumedTrustedIds = mutableSetOf<String>()

    fun findTrusted(deviceId: String, deviceCode: String): TrustedPeer? {
        val normCode = deviceCode.filter { it.isDigit() }
        return trustedPeers.firstOrNull { tp ->
            (deviceId.isNotBlank() && tp.deviceId == deviceId) ||
                (normCode.length == 9 && tp.deviceCode.filter { it.isDigit() } == normCode)
        }
    }

    fun findBookEntry(deviceId: String, deviceCode: String, ip: String): DeviceBookEntry? {
        val normCode = deviceCode.filter { it.isDigit() }
        return deviceBook.firstOrNull { d ->
            (deviceId.isNotBlank() && d.remoteDeviceId == deviceId) ||
                (normCode.length == 9 && d.deviceCode.filter { it.isDigit() } == normCode) ||
                (ip.isNotBlank() && d.target == ip)
        }
    }

    // 1. LAN Discovered Peers (always online, green dot)
    for (peer in lanPeers) {
        val trusted = findTrusted(peer.deviceId, peer.deviceCode)
        val book = findBookEntry(peer.deviceId, peer.deviceCode, peer.primaryAddress)
        trusted?.let { consumedTrustedIds.add(it.deviceId) }
        book?.let { consumedBookIds.add(it.id) }

        val subtitle = buildString {
            append("局域网 · ")
            append(peer.primaryAddress.ifBlank { peer.deviceCode.ifBlank { "在线" } })
            if (trusted != null) append(" · 已信任 · 免密")
        }
        rows.add(
            HostRowItem(
                key = "lan_${peer.deviceId.ifBlank { "${peer.primaryAddress}:${peer.port}" }}",
                name = book?.alias?.ifBlank { peer.deviceName } ?: peer.deviceName,
                subtitle = subtitle,
                isOnline = true,
                isTrusted = trusted != null,
                isFavorite = book?.favorite == true,
                savedPin = book?.savedPin.orEmpty(),
                bookEntry = book,
                trustedPeer = trusted,
                lanPeer = peer,
                connectAction = { pin ->
                    if (peer.primaryAddress.isNotBlank()) {
                        viewModel.connectDirect(peer.primaryAddress, peer.port, pin)
                    } else {
                        viewModel.connectSmart(peer.deviceCode.ifBlank { peer.deviceId }, peer.port, pin)
                    }
                }
            )
        )
    }

    // 2. Saved Device Book Entries
    for (entry in deviceBook) {
        if (entry.id in consumedBookIds) continue
        val trusted = findTrusted(entry.remoteDeviceId, entry.deviceCode.ifBlank { entry.target })
        trusted?.let { consumedTrustedIds.add(it.deviceId) }
        val probe = probeResults[entry.id]

        val subtitle = buildList {
            add(entry.displayTarget)
            if (trusted != null) {
                add("已信任 · 免密")
            }
            if (probe != null && probe.online) {
                add(probe.label)
            }
        }.joinToString(" · ")

        rows.add(
            HostRowItem(
                key = "book_${entry.id}",
                name = entry.alias,
                subtitle = subtitle,
                isOnline = probe?.online == true,
                isTrusted = trusted != null,
                isFavorite = entry.favorite,
                savedPin = entry.savedPin,
                bookEntry = entry,
                trustedPeer = trusted,
                lanPeer = null,
                connectAction = { pin ->
                    viewModel.connectSmart(entry.target, entry.port, pin)
                }
            )
        )
    }

    // 3. Any Trusted Peers not already represented
    for (tp in trustedPeers) {
        if (tp.deviceId in consumedTrustedIds) continue
        val codeLabel = tp.deviceCode.takeIf { it.length == 9 }
            ?.let { "${it.substring(0, 3)} ${it.substring(3, 6)} ${it.substring(6, 9)}" }
            ?: tp.deviceId.take(12)
        rows.add(
            HostRowItem(
                key = "trusted_${tp.deviceId.ifBlank { tp.endpointId }}",
                name = tp.deviceName,
                subtitle = "$codeLabel · 已信任 · 免密",
                isOnline = false,
                isTrusted = true,
                isFavorite = false,
                savedPin = "",
                bookEntry = null,
                trustedPeer = tp,
                lanPeer = null,
                connectAction = { pin ->
                    viewModel.connectSmart(tp.connectTarget, OpenUUConstants.DEFAULT_PORT, pin)
                }
            )
        )
    }

    return rows
}

@Composable
private fun PinPromptDialog(
    hostName: String,
    onDismiss: () -> Unit,
    onConfirm: (String) -> Unit
) {
    var pin by remember { mutableStateOf("") }
    var showPin by remember { mutableStateOf(false) }
    val focusRequester = remember { FocusRequester() }

    LaunchedEffect(Unit) {
        delay(80L)
        focusRequester.requestFocus()
    }

    AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = SurfaceCard,
        title = {
            Text(
                text = "连接至 $hostName",
                style = MaterialTheme.typography.titleMedium,
                color = TextPrimary
            )
        },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(
                    text = "首次连接需要输入 Mac 端显示的配对码，连接成功后将自动信任免密。",
                    style = MaterialTheme.typography.bodySmall,
                    color = TextSecondary
                )
                OutlinedTextField(
                    value = pin,
                    onValueChange = { pin = it },
                    placeholder = { Text("输入配对码 / 访问密码", color = TextMuted) },
                    singleLine = true,
                    visualTransformation = if (showPin) VisualTransformation.None else PasswordVisualTransformation(),
                    trailingIcon = {
                        IconButton(
                            onClick = { showPin = !showPin },
                            modifier = Modifier.size(32.dp)
                        ) {
                            Icon(
                                imageVector = if (showPin) Icons.Rounded.VisibilityOff else Icons.Rounded.Visibility,
                                contentDescription = if (showPin) "隐藏密码" else "显示密码",
                                tint = TextSecondary,
                                modifier = Modifier.size(18.dp)
                            )
                        }
                    },
                    shape = RoundedCornerShape(9.dp),
                    keyboardOptions = KeyboardOptions(
                        keyboardType = KeyboardType.Password,
                        imeAction = ImeAction.Done
                    ),
                    keyboardActions = KeyboardActions(onDone = { onConfirm(pin) }),
                    modifier = Modifier
                        .fillMaxWidth()
                        .focusRequester(focusRequester),
                    colors = industrialTextFieldColors()
                )
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text("取消", color = TextSecondary)
            }
        },
        confirmButton = {
            Button(
                onClick = { onConfirm(pin) },
                shape = RoundedCornerShape(8.dp),
                colors = ButtonDefaults.buttonColors(
                    containerColor = TextPrimary,
                    contentColor = BgObsidian
                )
            ) {
                Text("连接", fontWeight = FontWeight.SemiBold)
            }
        }
    )
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
        mutableStateOf(TextFieldValue(formatted, TextRange(formatted.length)))
    }
    var portText by remember(initial) {
        mutableStateOf((initial?.port ?: OpenUUConstants.DEFAULT_PORT).toString())
    }
    var savedPin by remember(initial) { mutableStateOf(initial?.savedPin.orEmpty()) }
    var showSavedPin by remember { mutableStateOf(false) }
    var favorite by remember(initial) { mutableStateOf(initial?.favorite ?: false) }

    AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = SurfaceCard,
        title = {
            Text(
                text = if (initial == null) "添加主机" else "编辑主机",
                style = MaterialTheme.typography.titleMedium,
                color = TextPrimary
            )
        },
        text = {
            Column(
                modifier = Modifier.verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(10.dp)
            ) {
                OutlinedTextField(
                    value = alias,
                    onValueChange = { alias = it },
                    label = { Text("名称 / 备注") },
                    singleLine = true,
                    shape = RoundedCornerShape(9.dp),
                    modifier = Modifier.fillMaxWidth(),
                    colors = industrialTextFieldColors()
                )
                OutlinedTextField(
                    value = targetField,
                    onValueChange = { targetField = formatTargetTextFieldValue(it, targetField.text) },
                    label = { Text("9 位设备码 / IP / openuu://") },
                    singleLine = true,
                    shape = RoundedCornerShape(9.dp),
                    modifier = Modifier.fillMaxWidth(),
                    colors = industrialTextFieldColors()
                )
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedTextField(
                        value = portText,
                        onValueChange = { portText = it.filter { ch -> ch.isDigit() } },
                        label = { Text("端口") },
                        singleLine = true,
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                        shape = RoundedCornerShape(9.dp),
                        modifier = Modifier.weight(0.9f),
                        colors = industrialTextFieldColors()
                    )
                    OutlinedTextField(
                        value = savedPin,
                        onValueChange = { savedPin = it },
                        label = { Text("配对码（可选）") },
                        singleLine = true,
                        visualTransformation = if (showSavedPin) VisualTransformation.None else PasswordVisualTransformation(),
                        trailingIcon = {
                            IconButton(
                                onClick = { showSavedPin = !showSavedPin },
                                modifier = Modifier.size(28.dp)
                            ) {
                                Icon(
                                    imageVector = if (showSavedPin) Icons.Rounded.VisibilityOff else Icons.Rounded.Visibility,
                                    contentDescription = if (showSavedPin) "隐藏密码" else "显示密码",
                                    tint = TextSecondary,
                                    modifier = Modifier.size(17.dp)
                                )
                            }
                        },
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
                        shape = RoundedCornerShape(9.dp),
                        modifier = Modifier.weight(1.3f),
                        colors = industrialTextFieldColors()
                    )
                }
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.SpaceBetween
                ) {
                    Text("置顶显示", style = MaterialTheme.typography.bodyMedium, color = TextPrimary)
                    Switch(checked = favorite, onCheckedChange = { favorite = it })
                }
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text("取消", color = TextSecondary)
            }
        },
        confirmButton = {
            Button(
                enabled = DeviceBookRepository.sanitizeTargetForUse(targetField.text).isNotBlank(),
                shape = RoundedCornerShape(8.dp),
                colors = ButtonDefaults.buttonColors(
                    containerColor = TextPrimary,
                    contentColor = BgObsidian
                ),
                onClick = {
                    val port = portText.toIntOrNull()?.coerceIn(1, 65535) ?: OpenUUConstants.DEFAULT_PORT
                    val cleanTarget = DeviceBookRepository.sanitizeTargetForUse(targetField.text)
                    onSave(
                        (initial ?: DeviceBookEntry(UUID.randomUUID().toString(), "", "")).copy(
                            alias = alias.trim().ifBlank { cleanTarget },
                            target = cleanTarget,
                            port = port,
                            savedPin = savedPin.trim(),
                            favorite = favorite
                        )
                    )
                }
            ) {
                Text("保存", fontWeight = FontWeight.SemiBold)
            }
        }
    )
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SettingsAndLogsSheet(
    viewModel: OpenUUViewModel,
    onDismiss: () -> Unit
) {
    val identity by viewModel.identity.collectAsState()
    val logs by viewModel.logs.collectAsState()
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)

    var coordUrl by remember(identity.wanConfig) { mutableStateOf(identity.wanConfig.coordUrl) }
    var relayUrl by remember(identity.wanConfig) { mutableStateOf(identity.wanConfig.relayUrl) }
    var relayAuthToken by remember(identity.wanConfig) { mutableStateOf(identity.wanConfig.relayAuthToken) }
    var enablePublicFallback by remember(identity.wanConfig) { mutableStateOf(identity.wanConfig.enablePublicFallback) }
    var allowInsecureTls by remember(identity.wanConfig) { mutableStateOf(identity.wanConfig.allowInsecureTls) }
    var savedFeedback by remember { mutableStateOf(false) }

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = SurfaceCard,
        contentColor = TextPrimary
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp)
                .padding(bottom = 28.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.SpaceBetween
            ) {
                Text("网络配置与运行日志", style = MaterialTheme.typography.titleMedium, color = TextPrimary)
                IconButton(
                    onClick = { viewModel.refreshIdentityAndDeviceBook() },
                    modifier = Modifier.size(30.dp)
                ) {
                    Icon(
                        imageVector = Icons.Rounded.Refresh,
                        contentDescription = "刷新",
                        tint = TextSecondary,
                        modifier = Modifier.size(18.dp)
                    )
                }
            }

            // Local Identity block
            Surface(
                color = SurfaceElevated,
                shape = RoundedCornerShape(10.dp),
                border = BorderStroke(0.5.dp, BorderHairline),
                modifier = Modifier.fillMaxWidth()
            ) {
                Column(
                    modifier = Modifier.padding(12.dp),
                    verticalArrangement = Arrangement.spacedBy(6.dp)
                ) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.SpaceBetween
                    ) {
                        Column {
                            Text("本机设备码", style = MaterialTheme.typography.labelSmall, color = TextSecondary)
                            Text(
                                text = identity.formattedCode.ifBlank { identity.deviceCode.ifBlank { "-" } },
                                fontFamily = FontFamily.Monospace,
                                fontSize = 18.sp,
                                fontWeight = FontWeight.SemiBold,
                                color = TextPrimary
                            )
                        }
                        TextButton(
                            onClick = {
                                val code = identity.formattedCode.ifBlank { identity.deviceCode }
                                viewModel.copyToLocalClipboard("设备码", code)
                            },
                            enabled = identity.deviceCode.isNotBlank()
                        ) {
                            Icon(Icons.Rounded.ContentCopy, contentDescription = null, modifier = Modifier.size(14.dp))
                            Spacer(Modifier.width(4.dp))
                            Text("复制", fontSize = 12.sp)
                        }
                    }
                    if (identity.endpointId.isNotBlank()) {
                        HorizontalDivider(thickness = 0.5.dp, color = DividerHairline)
                        Text(
                            text = "Endpoint: ${identity.endpointId}",
                            fontFamily = FontFamily.Monospace,
                            fontSize = 11.sp,
                            color = TextSecondary,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis
                        )
                    }
                    if (identity.coordStatus.isNotBlank()) {
                        Text(
                            text = "协调状态: ${identity.coordStatus}",
                            fontSize = 11.sp,
                            color = TextSecondary
                        )
                    }
                }
            }

            // Software Version & Auto-Update block
            val updPolicy by viewModel.updater.policy.collectAsState()
            val updChecking by viewModel.updater.isChecking.collectAsState()
            val updSummary by viewModel.updater.statusSummary.collectAsState()
            val updInfo by viewModel.updater.releaseInfo.collectAsState()
            var policyMenuOpen by remember { mutableStateOf(false) }

            Surface(
                color = SurfaceElevated,
                shape = RoundedCornerShape(10.dp),
                border = BorderStroke(0.5.dp, BorderHairline),
                modifier = Modifier.fillMaxWidth()
            ) {
                Column(
                    modifier = Modifier.padding(12.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.SpaceBetween
                    ) {
                        Column(modifier = Modifier.weight(1f)) {
                            Text("版本与自动更新", style = MaterialTheme.typography.labelSmall, color = TextSecondary)
                            Text(
                                text = "${AppUpdater.displayVersion} · $updSummary",
                                fontSize = 12.5.sp,
                                fontWeight = FontWeight.Medium,
                                color = if (updInfo?.hasUpdate == true) Color(0xFFFF9F0A) else TextPrimary
                            )
                        }
                        Button(
                            onClick = { viewModel.updater.checkForUpdates(manual = true) },
                            enabled = !updChecking,
                            shape = RoundedCornerShape(8.dp),
                            colors = ButtonDefaults.buttonColors(containerColor = TextPrimary, contentColor = BgObsidian),
                            contentPadding = PaddingValues(horizontal = 11.dp, vertical = 6.dp)
                        ) {
                            Text(if (updChecking) "检查中..." else "检查更新", fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
                        }
                    }

                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.SpaceBetween
                    ) {
                        Text("自动检查策略", fontSize = 12.sp, color = TextSecondary)
                        Box {
                            OutlinedButton(
                                onClick = { policyMenuOpen = true },
                                shape = RoundedCornerShape(8.dp),
                                border = BorderStroke(0.5.dp, BorderHairline),
                                contentPadding = PaddingValues(horizontal = 10.dp, vertical = 4.dp)
                            ) {
                                Text(updPolicy.label, fontSize = 12.sp, color = TextPrimary)
                            }
                            DropdownMenu(
                                expanded = policyMenuOpen,
                                onDismissRequest = { policyMenuOpen = false },
                                containerColor = SurfaceCard
                            ) {
                                UpdateCheckPolicy.entries.forEach { item ->
                                    DropdownMenuItem(
                                        text = { Text(item.label, color = TextPrimary, fontSize = 13.sp) },
                                        onClick = {
                                            viewModel.updater.setPolicy(item)
                                            policyMenuOpen = false
                                        }
                                    )
                                }
                            }
                        }
                    }

                    if (updInfo != null) {
                        TextButton(
                            onClick = {
                                onDismiss()
                                viewModel.updater.setShowUpdateDialog(true)
                            },
                            contentPadding = PaddingValues(0.dp)
                        ) {
                            Text(
                                text = if (updInfo?.hasUpdate == true) "查看新版本更新内容并一键安装 ➔" else "查看当前版本说明 ➔",
                                fontSize = 12.sp,
                                color = if (updInfo?.hasUpdate == true) Color(0xFFFF9F0A) else TextSecondary
                            )
                        }
                    }
                }
            }

            // WAN Coord & Relay Config
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Text("跨网协调与中继 (WAN)", style = MaterialTheme.typography.labelMedium, color = TextSecondary)
                OutlinedTextField(
                    value = coordUrl,
                    onValueChange = { coordUrl = it; savedFeedback = false },
                    label = { Text("Coord URL") },
                    singleLine = true,
                    shape = RoundedCornerShape(9.dp),
                    modifier = Modifier.fillMaxWidth(),
                    colors = industrialTextFieldColors()
                )
                OutlinedTextField(
                    value = relayUrl,
                    onValueChange = { relayUrl = it; savedFeedback = false },
                    label = { Text("Relay URL") },
                    singleLine = true,
                    shape = RoundedCornerShape(9.dp),
                    modifier = Modifier.fillMaxWidth(),
                    colors = industrialTextFieldColors()
                )
                OutlinedTextField(
                    value = relayAuthToken,
                    onValueChange = { relayAuthToken = it; savedFeedback = false },
                    label = { Text("Relay Auth Token（可选）") },
                    singleLine = true,
                    shape = RoundedCornerShape(9.dp),
                    modifier = Modifier.fillMaxWidth(),
                    colors = industrialTextFieldColors()
                )
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.SpaceBetween
                ) {
                    Column(modifier = Modifier.weight(1f)) {
                        Text("允许回退公共中继", style = MaterialTheme.typography.bodyMedium, color = TextPrimary)
                        Text("自建节点不可达时自动回退", style = MaterialTheme.typography.bodySmall, color = TextSecondary)
                    }
                    Switch(
                        checked = enablePublicFallback,
                        onCheckedChange = { enablePublicFallback = it; savedFeedback = false }
                    )
                }
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.SpaceBetween
                ) {
                    Column(modifier = Modifier.weight(1f)) {
                        Text("允许自签名 HTTPS 证书", style = MaterialTheme.typography.bodyMedium, color = TextPrimary)
                        Text("仅用于内网自建节点测试", style = MaterialTheme.typography.bodySmall, color = TextSecondary)
                    }
                    Switch(
                        checked = allowInsecureTls,
                        onCheckedChange = { allowInsecureTls = it; savedFeedback = false }
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
                        savedFeedback = true
                    },
                    shape = RoundedCornerShape(9.dp),
                    colors = ButtonDefaults.buttonColors(containerColor = TextPrimary, contentColor = BgObsidian),
                    modifier = Modifier.fillMaxWidth()
                ) {
                    if (savedFeedback) {
                        Icon(Icons.Rounded.Check, contentDescription = null, modifier = Modifier.size(16.dp))
                        Spacer(Modifier.width(5.dp))
                    }
                    Text(if (savedFeedback) "已保存 WAN 配置" else "保存 WAN 配置", fontWeight = FontWeight.SemiBold)
                }
            }

            // Live Logs
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.SpaceBetween
                ) {
                    Text("实时日志 (${logs.size})", style = MaterialTheme.typography.labelMedium, color = TextSecondary)
                    Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                        TextButton(
                            onClick = { viewModel.copyToLocalClipboard("运行日志", logs.joinToString("\n")) },
                            enabled = logs.isNotEmpty()
                        ) { Text("复制", fontSize = 12.sp, color = TextPrimary) }
                        TextButton(
                            onClick = { viewModel.clearLogs() },
                            enabled = logs.isNotEmpty()
                        ) { Text("清空", fontSize = 12.sp, color = TextSecondary) }
                    }
                }
                Surface(
                    color = BgObsidian,
                    shape = RoundedCornerShape(9.dp),
                    border = BorderStroke(0.5.dp, BorderHairline),
                    modifier = Modifier
                        .fillMaxWidth()
                        .heightIn(min = 140.dp, max = 240.dp)
                ) {
                    if (logs.isEmpty()) {
                        Box(modifier = Modifier.padding(12.dp)) {
                            Text(
                                text = "暂无日志输出",
                                fontFamily = FontFamily.Monospace,
                                fontSize = 11.sp,
                                color = TextMuted
                            )
                        }
                    } else {
                        Column(
                            modifier = Modifier
                                .fillMaxWidth()
                                .verticalScroll(rememberScrollState())
                                .padding(10.dp),
                            verticalArrangement = Arrangement.spacedBy(3.dp)
                        ) {
                            logs.asReversed().forEach { line ->
                                Text(
                                    text = line,
                                    fontFamily = FontFamily.Monospace,
                                    fontSize = 11.sp,
                                    lineHeight = 15.sp,
                                    color = when {
                                        line.contains("ERROR", ignoreCase = true) || line.contains("失败") -> StatusDanger
                                        line.contains("connected", ignoreCase = true) || line.contains("已就绪") -> StatusOnline
                                        else -> Color(0xFFD4D4D8)
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

@Composable
private fun SoftwareUpdateDialog(
    updater: AppUpdater,
    onDismiss: () -> Unit
) {
    val context = LocalContext.current
    val info by updater.releaseInfo.collectAsState()
    val isChecking by updater.isChecking.collectAsState()
    val installState by updater.installState.collectAsState()
    val hasUpdate = info?.hasUpdate == true

    AlertDialog(
        onDismissRequest = {
            if (!installState.isBusy) onDismiss()
        },
        containerColor = SurfaceCard,
        title = {
            Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
                Text(
                    text = if (hasUpdate) "发现新版本 ${info?.tagName.orEmpty()}" else "当前已是最新版本",
                    style = MaterialTheme.typography.titleMedium,
                    color = TextPrimary
                )
                val meta = listOfNotNull(
                    "当前 ${AppUpdater.displayVersion}",
                    info?.formattedDate?.takeIf { it.isNotBlank() },
                    info?.formattedSize?.takeIf { it.isNotBlank() }
                ).joinToString(" · ")
                Text(
                    text = meta,
                    fontFamily = FontFamily.Monospace,
                    fontSize = 11.5.sp,
                    color = TextSecondary
                )
            }
        },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Text("更新内容说明", fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = TextSecondary)
                Surface(
                    color = BgObsidian,
                    shape = RoundedCornerShape(10.dp),
                    border = BorderStroke(0.5.dp, BorderHairline),
                    modifier = Modifier
                        .fillMaxWidth()
                        .heightIn(min = 120.dp, max = 230.dp)
                ) {
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .verticalScroll(rememberScrollState())
                            .padding(11.dp)
                    ) {
                        Text(
                            text = info?.releaseNotes?.ifBlank { "暂无详细更新说明，可前往 GitHub Releases 查看完整变更记录。" }
                                ?: "暂无更新说明",
                            fontSize = 12.5.sp,
                            lineHeight = 18.sp,
                            color = TextPrimary
                        )
                    }
                }

                when (val st = installState) {
                    ApkInstallState.Idle -> Unit
                    is ApkInstallState.Downloading -> {
                        val doneMb = st.downloadedBytes / 1048576.0
                        Column(verticalArrangement = Arrangement.spacedBy(5.dp)) {
                            Row(
                                modifier = Modifier.fillMaxWidth(),
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.SpaceBetween
                            ) {
                                val label = if (st.totalBytes > 0L) {
                                    val totMb = st.totalBytes / 1048576.0
                                    val pct = ((st.downloadedBytes * 100L) / st.totalBytes).coerceIn(0L, 100L)
                                    String.format("正在下载：%.1f / %.1f MB (%d%%)", doneMb, totMb, pct)
                                } else {
                                    String.format("正在下载：%.1f MB...", doneMb)
                                }
                                Text(label, fontFamily = FontFamily.Monospace, fontSize = 11.5.sp, color = TextPrimary)
                                TextButton(
                                    onClick = { updater.cancelDownload() },
                                    contentPadding = PaddingValues(horizontal = 6.dp, vertical = 2.dp)
                                ) {
                                    Text("取消", fontSize = 11.5.sp, color = TextSecondary)
                                }
                            }
                            if (st.totalBytes > 0L) {
                                LinearProgressIndicator(
                                    progress = { (st.downloadedBytes.toFloat() / st.totalBytes.toFloat()).coerceIn(0f, 1f) },
                                    modifier = Modifier.fillMaxWidth()
                                )
                            } else {
                                LinearProgressIndicator(modifier = Modifier.fillMaxWidth())
                            }
                        }
                    }
                    is ApkInstallState.ReadyToInstall -> {
                        Text(st.message, fontSize = 12.sp, color = StatusOnline)
                    }
                    is ApkInstallState.Failed -> {
                        Text(st.error, fontSize = 12.sp, color = Color(0xFFFF8A80))
                    }
                }

                if (hasUpdate) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween
                    ) {
                        TextButton(
                            onClick = { updater.skipCurrentAvailableVersion() },
                            enabled = !installState.isBusy
                        ) {
                            Text("忽略此版本", fontSize = 12.sp, color = TextSecondary)
                        }
                        TextButton(
                            onClick = { updater.openReleaseInBrowser(context) }
                        ) {
                            Text("浏览器下载", fontSize = 12.sp, color = TextSecondary)
                        }
                    }
                }
            }
        },
        dismissButton = {
            TextButton(
                onClick = onDismiss,
                enabled = !installState.isBusy
            ) {
                Text(if (hasUpdate) "稍后" else "关闭", color = TextSecondary)
            }
        },
        confirmButton = {
            if (hasUpdate) {
                val btnText = when (installState) {
                    is ApkInstallState.Downloading -> "下载中..."
                    is ApkInstallState.ReadyToInstall -> "立即安装"
                    else -> "一键下载并安装"
                }
                Button(
                    onClick = { updater.startDownloadAndInstallApk(context) },
                    enabled = !installState.isBusy,
                    shape = RoundedCornerShape(8.dp),
                    colors = ButtonDefaults.buttonColors(containerColor = TextPrimary, contentColor = BgObsidian)
                ) {
                    Text(btnText, fontWeight = FontWeight.SemiBold)
                }
            } else {
                Button(
                    onClick = { updater.checkForUpdates(manual = true) },
                    enabled = !isChecking,
                    shape = RoundedCornerShape(8.dp),
                    colors = ButtonDefaults.buttonColors(containerColor = TextPrimary, contentColor = BgObsidian)
                ) {
                    Text(if (isChecking) "检查中..." else "重新检查", fontWeight = FontWeight.SemiBold)
                }
            }
        }
    )
}

@Composable
private fun industrialTextFieldColors() = OutlinedTextFieldDefaults.colors(
    focusedContainerColor = SurfaceInput,
    unfocusedContainerColor = SurfaceInput,
    focusedBorderColor = Color(0xFF52525B),
    unfocusedBorderColor = BorderHairline,
    focusedTextColor = TextPrimary,
    unfocusedTextColor = TextPrimary,
    focusedLabelColor = TextSecondary,
    unfocusedLabelColor = TextSecondary,
    cursorColor = TextPrimary
)

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
    if (formatted.isEmpty()) return TextFieldValue("", TextRange(0))

    val prefix = raw.substring(0, cursor.coerceAtMost(raw.length))
    val isCode = DeviceBookRepository.isDeviceCodeLike(formatted)
    val countBefore = if (isCode) prefix.count { it in '0'..'9' } else prefix.count { !it.isWhitespace() }
    val newCursor = if (countBefore == 0) {
        0
    } else {
        var seen = 0
        var pos = formatted.length
        for (i in formatted.indices) {
            val match = if (isCode) formatted[i] in '0'..'9' else !formatted[i].isWhitespace()
            if (match && ++seen == countBefore) {
                pos = i + 1
                break
            }
        }
        pos
    }

    return TextFieldValue(formatted, TextRange(newCursor.coerceIn(0, formatted.length)))
}
