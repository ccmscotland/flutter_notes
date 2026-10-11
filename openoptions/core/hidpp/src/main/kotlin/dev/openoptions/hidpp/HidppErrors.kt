package dev.openoptions.hidpp

sealed class HidppException(message: String) : Exception(message)

class HidppTimeoutException(val request: HidppFrame) : HidppException("No response to $request")

class Hidpp20Exception(val code: Int, val featureIndex: Int, val function: Int) :
    HidppException("HID++ 2.0 error ${Hidpp20Error.name(code)} (feature index ${featureIndex.hex()}, function $function)")

class Hidpp10Exception(val code: Int, val subId: Int, val address: Int) :
    HidppException("HID++ 1.0 error ${Hidpp10Error.name(code)} (sub-id ${subId.hex()}, address ${address.hex()})")

class FeatureNotSupportedException(val featureId: Int) :
    HidppException("Device does not implement feature ${Features.name(featureId)}")

object Hidpp20Error {
    const val NO_ERROR = 0x00
    const val UNKNOWN = 0x01
    const val INVALID_ARGUMENT = 0x02
    const val OUT_OF_RANGE = 0x03
    const val HW_ERROR = 0x04
    const val LOGITECH_INTERNAL = 0x05
    const val INVALID_FEATURE_INDEX = 0x06
    const val INVALID_FUNCTION_ID = 0x07
    const val BUSY = 0x08
    const val UNSUPPORTED = 0x09

    fun name(code: Int): String = when (code) {
        NO_ERROR -> "NoError"
        UNKNOWN -> "Unknown"
        INVALID_ARGUMENT -> "InvalidArgument"
        OUT_OF_RANGE -> "OutOfRange"
        HW_ERROR -> "HwError"
        LOGITECH_INTERNAL -> "LogitechInternal"
        INVALID_FEATURE_INDEX -> "InvalidFeatureIndex"
        INVALID_FUNCTION_ID -> "InvalidFunctionId"
        BUSY -> "Busy"
        UNSUPPORTED -> "Unsupported"
        else -> "0x${code.hex()}"
    }
}

object Hidpp10Error {
    const val INVALID_SUBID = 0x01
    const val INVALID_ADDRESS = 0x02
    const val INVALID_VALUE = 0x03
    const val CONNECT_FAIL = 0x04
    const val TOO_MANY_DEVICES = 0x05
    const val ALREADY_EXISTS = 0x06
    const val BUSY = 0x07
    const val UNKNOWN_DEVICE = 0x08
    const val RESOURCE_ERROR = 0x09
    const val REQUEST_UNAVAILABLE = 0x0A
    const val INVALID_PARAM_VALUE = 0x0B
    const val WRONG_PIN_CODE = 0x0C

    fun name(code: Int): String = when (code) {
        INVALID_SUBID -> "InvalidSubId"
        INVALID_ADDRESS -> "InvalidAddress"
        INVALID_VALUE -> "InvalidValue"
        CONNECT_FAIL -> "ConnectFail"
        TOO_MANY_DEVICES -> "TooManyDevices"
        ALREADY_EXISTS -> "AlreadyExists"
        BUSY -> "Busy"
        UNKNOWN_DEVICE -> "UnknownDevice"
        RESOURCE_ERROR -> "ResourceError"
        REQUEST_UNAVAILABLE -> "RequestUnavailable"
        INVALID_PARAM_VALUE -> "InvalidParamValue"
        WRONG_PIN_CODE -> "WrongPinCode"
        else -> "0x${code.hex()}"
    }
}
