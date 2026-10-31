package dev.filipfan.polyengineinfer.ui.chat

import android.content.Context
import dev.filipfan.polyengineinfer.api.LlmInferenceEngine
import dev.filipfan.polyengineinfer.api.LlmInferenceOptions
import dev.filipfan.polyengineinfer.api.LlmModelFiles
import dev.filipfan.polyengineinfer.chattemplate.BuiltInTemplates
import dev.filipfan.polyengineinfer.chattemplate.TemplateFormatter
import dev.filipfan.polyengineinfer.llamacpp.LlamaCppInference
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.onCompletion
import kotlinx.coroutines.flow.onStart
import java.io.File
import java.io.FileNotFoundException

/** Holds performance statistics for a single inference pass. */
data class InferenceStats(
    val prefillTokens: Int,
    val prefillSpeed: Float,
    val decodeTokens: Int,
    val decodeSpeed: Float,
    val timeToFirstToken: Long,
    val latency: Long,
)

/** Represents the different states of the model generation process. */
sealed interface GenerationResult {
    data class Started(val formattedMessage: String) : GenerationResult
    data class Partial(val token: String) : GenerationResult
    data class Complete(val fullResponse: String, val stats: InferenceStats) : GenerationResult
    data class Error(val throwable: Throwable) : GenerationResult
}

class ChatModelHelper(
    context: Context,
    private val modelFiles: LlmModelFiles,
    private val options: LlmInferenceOptions,
    templateType: BuiltInTemplates?,
    private val systemPrompt: String,
) {
    private var templateFormatter: TemplateFormatter? = null
    private val engine: LlmInferenceEngine
    private var modelTag: String = ""

    init {
        engine = createEngineFromPath(context, modelFiles.modelPath)
            templateType?.let {
                templateFormatter = TemplateFormatter(it)
        }
    }

    suspend fun load() {
        engine.load(modelFiles, options)
    }

    fun getModelTag(): String = modelTag

    fun generate(userPrompt: String): Flow<GenerationResult> = flow {
        val fullResponse = StringBuilder()
        val prompt = templateFormatter?.run {
            val formattedSystem = systemPrompt.takeIf { it.isNotBlank() }
                ?.let { formatSystemContent(it) }
                ?: ""
            formattedSystem + formatContent(userPrompt)
        } ?: userPrompt

        var firstRun = true
        var firstTokenTs = 0L
        var decodeTokens = 0
        val startTime = System.currentTimeMillis()

        engine.generate(prompt).onStart {
            emit(GenerationResult.Started(prompt))
        }.onCompletion {
            val endTime = System.currentTimeMillis()
            val prefillTokens = engine.getLatestGenerationPromptTokenSize()
            val timeToFirstToken = firstTokenTs - startTime
            val prefillSpeed = if (timeToFirstToken > 0) {
                prefillTokens / (timeToFirstToken / 1000f)
            } else {
                0f
            }
            val decodeTime = endTime - firstTokenTs
            val decodeSpeed = if (decodeTime > 0) {
                (decodeTokens - 1) / (decodeTime / 1000f)
            } else {
                0f
            }
            val latencyMs = endTime - startTime

            val stats = InferenceStats(
                prefillTokens = prefillTokens,
                prefillSpeed = prefillSpeed,
                decodeTokens = decodeTokens,
                decodeSpeed = decodeSpeed,
                timeToFirstToken = timeToFirstToken,
                latency = latencyMs,
            )
            emit(GenerationResult.Complete(fullResponse.toString(), stats))
        }.collect { token ->
            if (firstRun) {
                firstTokenTs = System.currentTimeMillis()
                firstRun = false
            }
            decodeTokens++
            fullResponse.append(token)
            emit(GenerationResult.Partial(token))
        }
    }.catch { e ->
        emit(GenerationResult.Error(e))
    }

    suspend fun release() {
        templateFormatter?.release()
        engine.unload()
        modelTag = ""
    }

    private fun createEngineFromPath(
        context: Context,
        modelPath: String,
    ): LlmInferenceEngine {
        val modelFile = File(modelPath)

        if (!modelFile.exists()) {
            throw FileNotFoundException("Path does not exist: $modelFile")
        }

        if (!modelFile.isFile) {
            throw IllegalArgumentException("GGUF model path must be a file: $modelPath")
                    }

        if (modelFile.extension.lowercase() != "gguf") {
            throw IllegalArgumentException("Only GGUF model is supported in poly-hard: ${modelFile.name}")
                    }

        modelTag = "${modelFile.name} (llama.cpp hard)"
        return LlamaCppInference()
    }
}
