package dev.openoptions.service

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/** Process-wide diagnostic log shown on the device and diagnostics screens. */
class LogBuffer(private val capacity: Int = 600) {
    private val _lines = MutableStateFlow<List<String>>(emptyList())
    val lines: StateFlow<List<String>> = _lines

    fun add(line: String) {
        val stamp = SimpleDateFormat("HH:mm:ss.SSS", Locale.US).format(Date())
        _lines.update { (it + "$stamp $line").takeLast(capacity) }
    }

    fun text(): String = _lines.value.joinToString("\n")
}
