package ren.onekb.openuu

import org.json.JSONArray
import java.io.File
import java.util.UUID

class DeviceBookRepository(filesDir: File) {
    private val file = File(filesDir, "device_book.json")
    private val lock = Any()

    fun loadAll(): List<DeviceBookEntry> = synchronized(lock) {
        if (!file.exists()) return emptyList()
        return try {
            val arr = JSONArray(file.readText(Charsets.UTF_8))
            val list = buildList {
                for (i in 0 until arr.length()) {
                    arr.optJSONObject(i)?.let { add(DeviceBookEntry.fromJson(it)) }
                }
            }
            sortEntries(list)
        } catch (_: Throwable) {
            emptyList()
        }
    }

    fun saveAll(entries: List<DeviceBookEntry>): List<DeviceBookEntry> = synchronized(lock) {
        val sorted = sortEntries(entries)
        try {
            file.parentFile?.mkdirs()
            val arr = JSONArray()
            sorted.forEach { arr.put(it.toJson()) }
            val tmp = File(file.parentFile, "${file.name}.tmp")
            tmp.writeText(arr.toString(2), Charsets.UTF_8)
            if (!tmp.renameTo(file)) {
                file.writeText(arr.toString(2), Charsets.UTF_8)
                tmp.delete()
            }
        } catch (_: Throwable) {
            // Ignore disk write failure on read-only storage
        }
        sorted
    }

    fun upsert(entry: DeviceBookEntry): List<DeviceBookEntry> = synchronized(lock) {
        val current = loadAll().toMutableList()
        val cleanTarget = entry.target.trim()
        val normDigits = extractNineDigitCode(cleanTarget)
        val normalized = entry.copy(
            id = entry.id.ifBlank { UUID.randomUUID().toString() },
            alias = entry.alias.trim().ifBlank { cleanTarget },
            target = cleanTarget,
            deviceCode = entry.deviceCode.ifBlank { normDigits }
        )

        val idx = current.indexOfFirst {
            it.id == normalized.id ||
                (cleanTarget.isNotEmpty() && it.target == cleanTarget) ||
                (normDigits.isNotEmpty() && it.deviceCode == normDigits)
        }
        if (idx >= 0) {
            val prev = current[idx]
            current[idx] = normalized.copy(
                id = prev.id,
                remoteDeviceId = normalized.remoteDeviceId.ifBlank { prev.remoteDeviceId },
                lastConnectedMs = maxOf(prev.lastConnectedMs, normalized.lastConnectedMs)
            )
        } else {
            current.add(normalized)
        }
        saveAll(current)
    }

    fun delete(id: String): List<DeviceBookEntry> = synchronized(lock) {
        saveAll(loadAll().filterNot { it.id == id })
    }

    fun toggleFavorite(id: String): List<DeviceBookEntry> = synchronized(lock) {
        val updated = loadAll().map {
            if (it.id == id) it.copy(favorite = !it.favorite) else it
        }
        saveAll(updated)
    }

    fun syncFromTrustedPeers(trustedPeers: List<TrustedPeer>): List<DeviceBookEntry> = synchronized(lock) {
        val current = loadAll().toMutableList()
        var changed = false
        for (tp in trustedPeers) {
            val normCode = tp.deviceCode.filter { it.isDigit() }
            val idx = current.indexOfFirst { d ->
                (tp.deviceId.isNotBlank() && d.remoteDeviceId == tp.deviceId) ||
                    (normCode.length == 9 && d.deviceCode == normCode) ||
                    (tp.lastTicket.isNotBlank() && d.target == tp.lastTicket)
            }
            if (idx >= 0) {
                var item = current[idx]
                if (item.remoteDeviceId.isBlank() && tp.deviceId.isNotBlank()) {
                    item = item.copy(remoteDeviceId = tp.deviceId)
                    changed = true
                }
                if (item.deviceCode.isBlank() && normCode.length == 9) {
                    item = item.copy(deviceCode = normCode)
                    changed = true
                }
                if (tp.lastConnectedMs > item.lastConnectedMs) {
                    item = item.copy(lastConnectedMs = tp.lastConnectedMs)
                    changed = true
                }
                current[idx] = item
            } else {
                val target = tp.connectTarget
                if (target.isNotBlank()) {
                    current.add(
                        DeviceBookEntry(
                            id = UUID.randomUUID().toString(),
                            alias = tp.deviceName.ifBlank { "远程 Mac" },
                            target = target,
                            port = OpenUUConstants.DEFAULT_PORT,
                            savedPin = "",
                            favorite = false,
                            notes = "",
                            remoteDeviceId = tp.deviceId,
                            deviceCode = normCode,
                            lastConnectedMs = tp.lastConnectedMs
                        )
                    )
                    changed = true
                }
            }
        }
        if (changed) saveAll(current) else sortEntries(current)
    }

    private fun sortEntries(list: List<DeviceBookEntry>): List<DeviceBookEntry> {
        return list.sortedWith(
            compareByDescending<DeviceBookEntry> { it.favorite }
                .thenByDescending { it.lastConnectedMs }
                .thenBy { it.alias.lowercase() }
        )
    }

    companion object {
        fun extractNineDigitCode(raw: String): String {
            val clean = raw.trim()
            if (clean.all { it.isDigit() || it == ' ' || it == '-' }) {
                val digits = clean.filter { it.isDigit() }
                if (digits.length == 9) return digits
            }
            return ""
        }
    }
}
