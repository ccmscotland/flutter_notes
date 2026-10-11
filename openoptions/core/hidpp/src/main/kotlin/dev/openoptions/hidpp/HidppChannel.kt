package dev.openoptions.hidpp

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeoutOrNull

/**
 * Request/response matching on top of a [HidppTransport].
 *
 * Requests are serialised (devices answer one at a time anyway). Any report that is not the response to the
 * in-flight request is published on [notifications].
 */
class HidppChannel(
    private val transport: HidppTransport,
    scope: CoroutineScope,
    private val timeoutMs: Long = 3_000,
) : AutoCloseable {

    /** Receiver index on a USB receiver, and the index of a directly connected (BLE or wired) device. */
    companion object {
        const val RECEIVER_INDEX = 0xFF
        const val DIRECT_DEVICE_INDEX = 0xFF

        private const val SUB_ID_SHORT_SET = 0x80
        private const val SUB_ID_SHORT_GET = 0x81
        private const val SUB_ID_LONG_SET = 0x82
        private const val SUB_ID_LONG_GET = 0x83
    }

    private class Pending(val matches: (HidppFrame) -> Boolean) {
        val response = CompletableDeferred<HidppFrame>()
    }

    private val mutex = Mutex()
    private var softwareId = 0

    @Volatile
    private var pending: Pending? = null

    private val _notifications = MutableSharedFlow<HidppFrame>(extraBufferCapacity = 128)
    val notifications: SharedFlow<HidppFrame> = _notifications

    /** Raw copy of every frame in both directions, for the diagnostics log. */
    private val _trace = MutableSharedFlow<Pair<Direction, HidppFrame>>(extraBufferCapacity = 256)
    val trace: SharedFlow<Pair<Direction, HidppFrame>> = _trace

    enum class Direction { OUT, IN }

    val supportedReports: Set<ReportType> get() = transport.supportedReports

    // UNDISPATCHED so the subscription exists before the constructor returns: a transport that answers
    // synchronously (or a reader thread that is already running) must never find no subscriber.
    private val collector: Job = scope.launch(start = CoroutineStart.UNDISPATCHED) {
        transport.incoming.collect { onFrame(it) }
    }

    private fun onFrame(frame: HidppFrame) {
        _trace.tryEmit(Direction.IN to frame)
        val p = pending
        if (p != null && !p.response.isCompleted && p.matches(frame)) {
            p.response.complete(frame)
        } else {
            _notifications.tryEmit(frame)
        }
    }

    private fun nextSoftwareId(): Int {
        softwareId = (softwareId % 15) + 1 // 1..15, never 0 (0 marks notifications)
        return softwareId
    }

    private suspend fun exchange(request: HidppFrame, matches: (HidppFrame) -> Boolean): HidppFrame {
        val p = Pending(matches)
        pending = p
        try {
            _trace.tryEmit(Direction.OUT to request)
            transport.write(request)
            return withTimeoutOrNull(timeoutMs) { p.response.await() } ?: throw HidppTimeoutException(request)
        } finally {
            pending = null
        }
    }

    /**
     * HID++ 2.0 feature call. Returns the response parameters (without the two header bytes).
     * Throws [Hidpp20Exception], [Hidpp10Exception] or [HidppTimeoutException].
     */
    suspend fun call(
        deviceIndex: Int,
        featureIndex: Int,
        function: Int,
        params: ByteArray = ByteArray(0),
        reportType: ReportType? = null,
    ): ByteArray = mutex.withLock {
        require(function in 0..15) { "Function must fit in a nibble" }
        val swId = nextSoftwareId()
        val address = (function shl 4) or swId
        val type = reportType ?: ReportType.smallestFor(params.size, transport.supportedReports)
        val request = HidppFrame.build(type, deviceIndex, featureIndex, address, params)
        val response = exchange(request) { r ->
            r.deviceIndex == deviceIndex && when {
                r.isHidpp20Error || r.isHidpp10Error -> r.body[1].u() == featureIndex && r.body[2].u() == address
                else -> r.subId == featureIndex && r.address == address
            }
        }
        when {
            response.isHidpp20Error -> throw Hidpp20Exception(response.body[3].u(), featureIndex, function)
            response.isHidpp10Error -> throw Hidpp10Exception(response.body[3].u(), featureIndex, address)
            else -> response.params
        }
    }

    /** HID++ 1.0 register read (receivers, and HID++ 1.0 devices). */
    suspend fun readRegister(deviceIndex: Int, register: Int, params: ByteArray = ByteArray(0), long: Boolean = false): ByteArray =
        registerOp(deviceIndex, if (long) SUB_ID_LONG_GET else SUB_ID_SHORT_GET, register, params)

    /** HID++ 1.0 register write. */
    suspend fun writeRegister(deviceIndex: Int, register: Int, params: ByteArray, long: Boolean = false): ByteArray =
        registerOp(deviceIndex, if (long) SUB_ID_LONG_SET else SUB_ID_SHORT_SET, register, params)

    private suspend fun registerOp(deviceIndex: Int, subId: Int, register: Int, params: ByteArray): ByteArray = mutex.withLock {
        val type = if (subId == SUB_ID_LONG_GET || subId == SUB_ID_LONG_SET) ReportType.LONG else ReportType.SHORT
        val request = HidppFrame.build(type, deviceIndex, subId, register, params)
        val response = exchange(request) { r ->
            r.deviceIndex == deviceIndex && when {
                r.isHidpp10Error -> r.body[1].u() == subId && r.body[2].u() == register
                else -> r.subId == subId && r.address == register
            }
        }
        if (response.isHidpp10Error) throw Hidpp10Exception(response.body[3].u(), subId, register)
        response.params
    }

    override fun close() {
        collector.cancel()
        transport.close()
    }
}
