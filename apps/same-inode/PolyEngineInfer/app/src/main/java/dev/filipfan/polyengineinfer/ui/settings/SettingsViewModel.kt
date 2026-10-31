package dev.filipfan.polyengineinfer.ui.settings

import androidx.lifecycle.ViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** Represents the built-in template options */
enum class ChatTemplateOptions {
    NONE,
    LLAMA3,
    GEMMA,
}

/** The backend to use for inference. */
enum class Backend {
    CPU,
    GPU,
}

/** Represents the configuration for loading and running a Large Language Model. */
data class LlmSettings(
    val modelPath: String,
    val tokenizerPath: String = "",
    val chatTemplate: ChatTemplateOptions = ChatTemplateOptions.NONE,
    val systemPrompt: String = "You are a helpful assistant.",
    val maxTokens: Int = 512,
    val topK: Int = 40,
    val topP: Float = 1.0f,
    val temperature: Float = 0.8f,
    val backend: Backend = Backend.CPU,
)

/** A ViewModel responsible for managing and exposing the settings for the UI. */
class SettingsViewModel : ViewModel() {
    private companion object {
        const val FIXED_MODEL_PATH = "/data/local/tmp/model.gguf"
    }

    private val _settings = MutableStateFlow(
        LlmSettings(
            modelPath = FIXED_MODEL_PATH,
        ),
    )

    val settings: StateFlow<LlmSettings> = _settings.asStateFlow()

    fun updateSettings(newSettings: LlmSettings) {
        _settings.value = newSettings
    }
}
