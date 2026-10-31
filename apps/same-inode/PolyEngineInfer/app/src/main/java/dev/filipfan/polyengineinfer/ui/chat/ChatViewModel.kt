package dev.filipfan.polyengineinfer.ui.chat

import android.app.Application
import androidx.compose.runtime.mutableStateListOf
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import dev.filipfan.polyengineinfer.api.LlmInferenceOptions
import dev.filipfan.polyengineinfer.api.LlmModelFiles
import dev.filipfan.polyengineinfer.chattemplate.BuiltInTemplates
import dev.filipfan.polyengineinfer.ui.settings.Backend
import dev.filipfan.polyengineinfer.ui.settings.ChatTemplateOptions
import dev.filipfan.polyengineinfer.ui.settings.LlmSettings
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/** Represents a single message in the chat. */
data class ChatMessage(
    val text: String,
    val isFromMe: Boolean,
    val stats: InferenceStats? = null,
    val showStats: Boolean = false,
)

/**
 * ViewModel for the chat screen, responsible for managing the state,
 * loading the LLM, and handling user interactions.
 */
class ChatViewModel(application: Application) : AndroidViewModel(application) {

    /** Sealed class for representing UI states clearly. */
    sealed class State {
        data object Uninitialized : State()

        data object Loading : State()

        data object Loaded : State()

        data object Generating : State()

        data class Error(val message: String?) : State()
    }

    private var chatModelHelper: ChatModelHelper? = null

    private var generationJob: Job? = null

    // Holds the list of messages.
    private val _messages = mutableStateListOf<ChatMessage>()
    val messages: List<ChatMessage> = _messages

    private val _uiState = MutableStateFlow<State>(State.Uninitialized)
    val uiState: StateFlow<State> = _uiState.asStateFlow()

    private val _currentModelTag = MutableStateFlow("ChatBot")
    val currentModelTag: StateFlow<String> = _currentModelTag.asStateFlow()

    fun loadModel(config: LlmSettings) {
        generationJob?.cancel()
        viewModelScope.launch {
            releaseEngine()
            _uiState.value = State.Loading
            try {
                chatModelHelper = ChatModelHelper(
                    getApplication(),
                    LlmModelFiles(
                        modelPath = config.modelPath,
                        tokenizerPath = config.tokenizerPath,
                    ),
                    LlmInferenceOptions(
                        maxTokens = config.maxTokens,
                        topK = config.topK,
                        topP = config.topP,
                        temperature = config.temperature,
                        backend = toApiBackend(config.backend),
                    ),
                    toBuiltInTemplate(config.chatTemplate),
                    config.systemPrompt,
                ).apply {
                    load()
                    _currentModelTag.value = getModelTag()
                }
            } catch (e: Exception) {
                _uiState.value = State.Error(e.message ?: e.toString())
                return@launch
            }
            _uiState.value = State.Loaded
        }
    }

    fun sendMessage(userInput: String) {
        generationJob?.cancel()

        val currentInstance = checkNotNull(chatModelHelper) { "Engine not loaded." }

        // Start generating a response.
        generationJob = viewModelScope.launch {
            currentInstance.generate(userInput)
                .collect { result ->
                    when (result) {
                        is GenerationResult.Started -> {
                            _uiState.value = State.Generating
                            // Add the formatted user's message to the list.
                            _messages.add(
                                ChatMessage(
                                    result.formattedMessage,
                                    isFromMe = true,
                                ),
                            )
                            _messages.add(ChatMessage("", isFromMe = false))
                        }

                        is GenerationResult.Partial -> {
                            val lastMessage = _messages.last()
                            val updatedText = lastMessage.text + result.token
                            _messages[_messages.lastIndex] = lastMessage.copy(text = updatedText)
                        }

                        is GenerationResult.Complete -> {
                            _uiState.value = State.Loaded
                            _messages[_messages.lastIndex] =
                                _messages.last().copy(stats = result.stats)
                        }

                        is GenerationResult.Error -> {
                            releaseEngine()
                            _uiState.value = State.Error(result.throwable.message)
                        }
                    }
                }
        }
    }

    fun toggleStatsVisibility(messageIndex: Int) {
        val message = _messages[messageIndex]
        _messages[messageIndex] = message.copy(showStats = !message.showStats)
    }

    override fun onCleared() {
        super.onCleared()
        generationJob?.cancel()
        viewModelScope.launch {
            releaseEngine()
        }
    }

    private suspend fun releaseEngine() {
        chatModelHelper?.release()
        chatModelHelper = null
        _messages.clear()
        _currentModelTag.value = ""
        _uiState.value = State.Uninitialized
    }

    private fun toBuiltInTemplate(template: ChatTemplateOptions): BuiltInTemplates? = when (template) {
        ChatTemplateOptions.LLAMA3 -> {
            BuiltInTemplates.LLAMA_3
        }

        ChatTemplateOptions.GEMMA -> {
            BuiltInTemplates.GEMMA
        }

        ChatTemplateOptions.NONE -> {
            null
        }
    }

    private fun toApiBackend(backend: Backend): LlmInferenceOptions.Backend = when (backend) {
        Backend.CPU -> {
            LlmInferenceOptions.Backend.CPU
        }

        Backend.GPU -> {
            LlmInferenceOptions.Backend.GPU
        }
    }
}
