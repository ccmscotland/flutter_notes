package dev.openoptions.hidpp

/**
 * One HID++ 2.0 device on a channel: feature-index discovery with caching, plus typed helpers.
 */
class Hidpp20Device(val channel: HidppChannel, val deviceIndex: Int) {

    private val featureIndexCache = HashMap<Int, Int?>()

    /** Root.ping. Returns 1.0 for HID++ 1.0 devices (they answer with an InvalidSubId error). */
    suspend fun ping(): ProtocolVersion {
        val marker = 0x5A
        return try {
            val r = channel.call(deviceIndex, 0x00, 1, byteArrayOf(0, 0, marker.toByte()))
            ProtocolVersion(r[0].u(), r[1].u())
        } catch (e: Hidpp10Exception) {
            if (e.code == Hidpp10Error.INVALID_SUBID) ProtocolVersion(1, 0) else throw e
        }
    }

    /** Root.getFeature → feature index, or null when the device lacks the feature. */
    suspend fun featureIndex(featureId: Int): Int? {
        if (featureId == Features.ROOT) return 0
        featureIndexCache[featureId]?.let { return it }
        if (featureIndexCache.containsKey(featureId)) return null
        val r = channel.call(deviceIndex, 0x00, 0, byteArrayOf((featureId shr 8).toByte(), featureId.toByte()))
        val index = r[0].u()
        val resolved = if (index == 0) null else index
        featureIndexCache[featureId] = resolved
        return resolved
    }

    suspend fun hasFeature(featureId: Int): Boolean = featureIndex(featureId) != null

    /** Calls [function] on [featureId]. Throws [FeatureNotSupportedException] when the device lacks it. */
    suspend fun call(featureId: Int, function: Int, params: ByteArray = ByteArray(0), reportType: ReportType? = null): ByteArray {
        val index = featureIndex(featureId) ?: throw FeatureNotSupportedException(featureId)
        return channel.call(deviceIndex, index, function, params, reportType)
    }

    /** Calls [function] on [featureId], or returns null when the device lacks it. */
    suspend fun callOrNull(featureId: Int, function: Int, params: ByteArray = ByteArray(0)): ByteArray? {
        val index = featureIndex(featureId) ?: return null
        return channel.call(deviceIndex, index, function, params)
    }

    /** FeatureSet enumeration. Index 0 (Root) is included. */
    suspend fun listFeatures(): List<FeatureEntry> {
        val setIndex = featureIndex(Features.FEATURE_SET) ?: return listOf(FeatureEntry(0, Features.ROOT, 0, 0))
        val count = channel.call(deviceIndex, setIndex, 0)[0].u()
        val entries = ArrayList<FeatureEntry>(count + 1)
        entries += FeatureEntry(0, Features.ROOT, 0, 0)
        for (i in 1..count) {
            val r = channel.call(deviceIndex, setIndex, 1, byteArrayOf(i.toByte()))
            val id = (r[0].u() shl 8) or r[1].u()
            entries += FeatureEntry(i, id, r[2].u(), r[3].u())
            featureIndexCache[id] = i
        }
        return entries
    }
}
