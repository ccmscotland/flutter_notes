package dev.openoptions.hidpp.features

import dev.openoptions.hidpp.Features
import dev.openoptions.hidpp.Hidpp20Device
import dev.openoptions.hidpp.u

data class HostSlot(val index: Int, val paired: Boolean, val name: String?, val isCurrent: Boolean)

data class HostsInfo(val hosts: List<HostSlot>, val canRename: Boolean) {
    val current: HostSlot? get() = hosts.firstOrNull { it.isCurrent }
}

/** Features 0x1815 HostsInfo (names, status) and 0x1814 ChangeHost (switching). */
object Hosts {
    private const val CHUNK = 14

    /** Current Easy-Switch slot (0-based). 0xFF when the device has neither feature. */
    suspend fun currentHostIndex(device: Hidpp20Device): Int {
        device.callOrNull(Features.HOSTS_INFO, 0)?.let { return it[3].u() }
        device.callOrNull(Features.CHANGE_HOST, 0)?.let { return it[1].u() }
        return 0xFF
    }

    suspend fun read(device: Hidpp20Device): HostsInfo? {
        val state = device.callOrNull(Features.HOSTS_INFO, 0)
        if (state != null) {
            val flags = state[0].u()
            val count = state[2].u()
            val current = state[3].u()
            val hosts = (0 until count).map { h ->
                val info = device.call(Features.HOSTS_INFO, 1, byteArrayOf(h.toByte()))
                val paired = info[1].u() != 0
                val nameLen = info[4].u()
                val name = if (flags and 0x01 != 0 && paired && nameLen > 0) readName(device, h, nameLen) else null
                HostSlot(h, paired, name, h == current)
            }
            return HostsInfo(hosts, canRename = flags and 0x02 != 0)
        }
        val ch = device.callOrNull(Features.CHANGE_HOST, 0) ?: return null
        val count = ch[0].u()
        val current = ch[1].u()
        return HostsInfo((0 until count).map { HostSlot(it, paired = true, name = null, isCurrent = it == current) }, canRename = false)
    }

    private suspend fun readName(device: Hidpp20Device, host: Int, length: Int): String {
        val bytes = ArrayList<Byte>(length)
        while (bytes.size < length) {
            val r = device.call(Features.HOSTS_INFO, 3, byteArrayOf(host.toByte(), bytes.size.toByte()))
            val piece = r.copyOfRange(2, 2 + minOf(CHUNK, length - bytes.size))
            if (piece.isEmpty()) break
            bytes += piece.toList()
        }
        return String(bytes.toByteArray(), Charsets.UTF_8).trimEnd('\u0000')
    }

    suspend fun rename(device: Hidpp20Device, host: Int, name: String) {
        val info = device.call(Features.HOSTS_INFO, 1, byteArrayOf(host.toByte()))
        val max = info[5].u()
        val bytes = name.toByteArray(Charsets.UTF_8).take(max).toByteArray()
        var offset = 0
        while (offset < bytes.size) {
            val chunk = bytes.copyOfRange(offset, minOf(offset + CHUNK, bytes.size))
            device.call(Features.HOSTS_INFO, 4, byteArrayOf(host.toByte(), offset.toByte()) + chunk)
            offset += chunk.size
        }
    }

    /**
     * Switches the device to another Easy-Switch slot. The device disconnects from this host immediately,
     * so no reply is expected; the request is sent and the timeout is swallowed.
     */
    suspend fun switchTo(device: Hidpp20Device, host: Int) {
        try {
            device.call(Features.CHANGE_HOST, 1, byteArrayOf(host.toByte()))
        } catch (_: dev.openoptions.hidpp.HidppTimeoutException) {
            // expected: the link is gone before the reply
        } catch (e: Exception) {
            // a transport error after the write (GATT disconnect) is the same thing; a HID++ error is real
            if (e is dev.openoptions.hidpp.Hidpp20Exception || e is dev.openoptions.hidpp.Hidpp10Exception) throw e
        }
    }
}
