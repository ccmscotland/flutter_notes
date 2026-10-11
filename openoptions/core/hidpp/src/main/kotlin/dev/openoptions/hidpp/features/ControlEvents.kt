package dev.openoptions.hidpp.features

import dev.openoptions.hidpp.HidppFrame
import dev.openoptions.hidpp.u

/** Decoded 0x1B04 notification. */
sealed class ControlEvent {
    /** The set of diverted controls currently held down (empty when all released). */
    data class Buttons(val pressed: Set<Int>) : ControlEvent()

    /** Relative pointer motion while a raw-XY diverted control is held. */
    data class RawXy(val dx: Int, val dy: Int) : ControlEvent()
}

/** Parses notifications from feature 0x1B04 ReprogControlsV4. */
object ControlEvents {
    private const val EVENT_BUTTONS = 0
    private const val EVENT_RAW_XY = 1

    /** Returns the event when [frame] is a notification from the feature at [featureIndex], else null. */
    fun parse(frame: HidppFrame, featureIndex: Int): ControlEvent? {
        if (frame.subId != featureIndex || frame.softwareId != 0) return null
        val p = frame.params
        return when (frame.function) {
            EVENT_BUTTONS -> ControlEvent.Buttons(parseDivertedButtons(p))
            EVENT_RAW_XY -> ControlEvent.RawXy(signed16(p, 0), signed16(p, 2))
            else -> null
        }
    }

    /** divertedButtonsEvent: up to four 16-bit control ids, zero-terminated. */
    fun parseDivertedButtons(p: ByteArray): Set<Int> {
        val out = LinkedHashSet<Int>()
        var i = 0
        while (i + 1 < p.size && out.size < 4) {
            val cid = (p[i].u() shl 8) or p[i + 1].u()
            if (cid == 0) break
            out += cid
            i += 2
        }
        return out
    }

    private fun signed16(p: ByteArray, i: Int): Int {
        if (i + 1 >= p.size) return 0
        return ((p[i].u() shl 8) or p[i + 1].u()).toShort().toInt()
    }
}

/** Turns the "currently pressed" sets from successive events into press and release transitions. */
class DivertedButtonTracker {
    private var pressed: Set<Int> = emptySet()

    data class Transition(val pressed: List<Int>, val released: List<Int>)

    fun update(now: Set<Int>): Transition {
        val t = Transition(pressed = (now - pressed).toList(), released = (pressed - now).toList())
        pressed = now
        return t
    }

    fun reset() { pressed = emptySet() }
}
