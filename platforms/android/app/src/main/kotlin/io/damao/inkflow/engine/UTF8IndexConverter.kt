package io.damao.inkflow.engine

internal object UTF8IndexConverter {
    /**
     * Converts a standard UTF-8 byte boundary into a Java/Kotlin UTF-16 offset.
     * The complete string is validated even when the requested offset is zero.
     */
    fun utf16Offset(text: String, byteOffset: Long): Int {
        require(byteOffset >= 0) { "UTF-8 offset must be nonnegative" }

        var utf16Index = 0
        var utf8Index = 0L
        var result: Int? = null
        while (utf16Index < text.length) {
            if (utf8Index == byteOffset) {
                result = utf16Index
            }

            val first = text[utf16Index]
            val codePoint: Int
            val utf16Width: Int
            when {
                first.isHighSurrogate() -> {
                    require(utf16Index + 1 < text.length) { "Unpaired UTF-16 high surrogate" }
                    val second = text[utf16Index + 1]
                    require(second.isLowSurrogate()) { "Unpaired UTF-16 high surrogate" }
                    codePoint = Character.toCodePoint(first, second)
                    utf16Width = 2
                }

                first.isLowSurrogate() -> throw IllegalArgumentException("Unpaired UTF-16 low surrogate")
                else -> {
                    codePoint = first.code
                    utf16Width = 1
                }
            }

            val utf8Width = when {
                codePoint <= 0x7f -> 1
                codePoint <= 0x7ff -> 2
                codePoint <= 0xffff -> 3
                else -> 4
            }
            val nextUtf8Index = utf8Index + utf8Width
            require(byteOffset <= utf8Index || byteOffset >= nextUtf8Index) {
                "Offset is inside a UTF-8 scalar"
            }
            utf8Index = nextUtf8Index
            utf16Index += utf16Width
        }

        if (utf8Index == byteOffset) {
            result = text.length
        }
        return requireNotNull(result) { "UTF-8 offset is outside the string" }
    }
}
