package dev.openoptions.hidpp

import kotlinx.coroutines.flow.Flow

/** A byte pipe to one HID++ endpoint: a USB receiver (multiplexing several devices) or one BLE device. */
interface HidppTransport : AutoCloseable {
    /** Every report received from the endpoint, responses and notifications alike. */
    val incoming: Flow<HidppFrame>

    /** Report types this endpoint accepts. BLE devices only take long reports. */
    val supportedReports: Set<ReportType>

    /** Human-readable description for logs and diagnostics. */
    val description: String

    suspend fun write(frame: HidppFrame)
}
