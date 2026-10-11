package dev.openoptions.hidpp.features

import dev.openoptions.hidpp.Features
import dev.openoptions.hidpp.Hidpp20Device
import dev.openoptions.hidpp.u

enum class DeviceType(val code: Int, val label: String) {
    KEYBOARD(0, "Keyboard"), REMOTE_CONTROL(1, "Remote control"), NUMPAD(2, "Numpad"), MOUSE(3, "Mouse"),
    TRACKPAD(4, "Trackpad"), TRACKBALL(5, "Trackball"), PRESENTER(6, "Presenter"), RECEIVER(7, "Receiver"),
    HEADSET(8, "Headset"), WEBCAM(9, "Webcam"), STEERING_WHEEL(10, "Steering wheel"), JOYSTICK(11, "Joystick"),
    GAMEPAD(12, "Gamepad"), DOCK(13, "Dock"), SPEAKER(14, "Speaker"), MICROPHONE(15, "Microphone"),
    ILLUMINATION_LIGHT(16, "Illumination light"), PROGRAMMABLE_CONTROLLER(17, "Programmable controller"),
    CAR_SIM_PEDALS(18, "Car sim pedals"), ADAPTER(19, "Adapter"), UNKNOWN(-1, "Unknown");

    companion object {
        fun fromCode(code: Int): DeviceType = entries.firstOrNull { it.code == code } ?: UNKNOWN
    }
}

/** Feature 0x0005 DeviceName. */
object DeviceName {
    suspend fun name(device: Hidpp20Device): String? {
        val count = device.callOrNull(Features.DEVICE_NAME, 0)?.get(0)?.u() ?: return null
        val sb = StringBuilder(count)
        while (sb.length < count) {
            val chunk = device.call(Features.DEVICE_NAME, 1, byteArrayOf(sb.length.toByte()))
            val usable = chunk.takeWhile { it.toInt() != 0 }.take(count - sb.length)
            if (usable.isEmpty()) break
            sb.append(String(usable.toByteArray(), Charsets.US_ASCII))
        }
        return sb.toString()
    }

    suspend fun type(device: Hidpp20Device): DeviceType? =
        device.callOrNull(Features.DEVICE_NAME, 2)?.let { DeviceType.fromCode(it[0].u()) }
}
