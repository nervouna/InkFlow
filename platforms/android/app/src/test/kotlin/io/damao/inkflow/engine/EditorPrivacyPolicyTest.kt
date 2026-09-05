package io.damao.inkflow.engine

import android.text.InputType
import android.view.inputmethod.EditorInfo
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class EditorPrivacyPolicyTest {
    @Test
    fun allPasswordVariationsBypassRime() {
        val sensitiveTypes = listOf(
            InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD,
            InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD,
            InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD,
            InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_VARIATION_PASSWORD,
        )

        sensitiveTypes.forEach { inputType ->
            assertTrue(EditorPrivacyPolicy.isSensitive(inputType, 0))
        }
    }

    @Test
    fun noPersonalizedLearningAlsoBypassesRime() {
        assertTrue(
            EditorPrivacyPolicy.isSensitive(
                InputType.TYPE_CLASS_TEXT,
                EditorInfo.IME_FLAG_NO_PERSONALIZED_LEARNING,
            ),
        )
    }

    @Test
    fun ordinaryTextUsesRime() {
        assertFalse(EditorPrivacyPolicy.isSensitive(InputType.TYPE_CLASS_TEXT, 0))
    }
}
