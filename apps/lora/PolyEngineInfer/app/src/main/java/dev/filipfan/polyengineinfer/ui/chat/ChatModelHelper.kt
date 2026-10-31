package dev.filipfan.polyengineinfer.ui.chat

import android.content.Context
import dev.filipfan.polyengineinfer.api.LlmInferenceEngine
import dev.filipfan.polyengineinfer.api.LlmInferenceOptions
import dev.filipfan.polyengineinfer.api.LlmModelFiles
import dev.filipfan.polyengineinfer.chattemplate.BuiltInTemplates
import dev.filipfan.polyengineinfer.chattemplate.TemplateFormatter
import dev.filipfan.polyengineinfer.executorch.ExecuTorchInference
import dev.filipfan.polyengineinfer.litertlm.LiteRtLmInference
import dev.filipfan.polyengineinfer.llamacpp.LlamaCppInference
import dev.filipfan.polyengineinfer.onnx.OnnxInference
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.onCompletion
import kotlinx.coroutines.flow.onStart
import java.io.File
import java.io.FileNotFoundException

/** Holds performance statistics for a single inference pass. */
data class InferenceStats(
    /** The total number of tokens in the input prompt that were processed. */
    val prefillTokens: Int,
    /** The processing speed of the prompt, measured in tokens per second (tokens/s). */
    val prefillSpeed: Float,
    /** The total number of generated tokens. */
    val decodeTokens: Int,
    /** The generation speed for the response, measured in tokens per second (tokens/s). */
    val decodeSpeed: Float,
    /**
     * The time from when the prompt is sent until the first response token is received,
     * measured in milliseconds (ms).
     */
    val timeToFirstToken: Long,
    /**
     * The total latency for the entire inference operation, from prompt submission to
     * receiving the final token, measured in milliseconds (ms).
     */
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

    private val effectiveModelPath: String = run {
        val cfg = File("/data/local/tmp/lora_ksm/poly/model_path.txt")
        if (cfg.exists() && cfg.canRead()) {
            cfg.readText().trim().ifEmpty { modelFiles.modelPath }
        } else {
            modelFiles.modelPath
        }
    }

    init {
        android.util.Log.i("LORA_KSM", "Poly effective model path: $effectiveModelPath")
        engine = createEngineFromPath(context, effectiveModelPath, modelFiles.tokenizerPath)
        // TODO: (refactor) LiteRT-LM built-in chat template.
        if (engine !is LiteRtLmInference) {
            templateType?.let {
                templateFormatter = TemplateFormatter(it)
            }
        }
    }

    suspend fun load() {
        val effectiveModelFiles = modelFiles.copy(modelPath = effectiveModelPath)
        android.util.Log.i("LORA_KSM", "Poly engine.load model path: ${effectiveModelFiles.modelPath}")
        engine.load(effectiveModelFiles, options)
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
        // Record the stats of generating.
        var firstRun = true
        var timeToFirstToken: Long
        var firstTokenTs = 0L
        var decodeTokens = 0
        var prefillSpeed: Float
        var decodeSpeed: Float
        val startTime = System.currentTimeMillis()

        engine.generate(prompt).onStart {
            emit(GenerationResult.Started(prompt))
        }.onCompletion {
            // Calculate the stats.
            val endTime = System.currentTimeMillis()
            val prefillTokens = engine.getLatestGenerationPromptTokenSize()
            timeToFirstToken = firstTokenTs - startTime
            prefillSpeed = prefillTokens / (timeToFirstToken / 1000f)
            decodeSpeed = (decodeTokens - 1) / ((endTime - firstTokenTs) / 1000f)
            val latencyMs: Long = endTime - startTime
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
        tokenizerPath: String,
    ): LlmInferenceEngine {
        val modelFile = File(modelPath)

        if (!modelFile.exists()) {
            throw FileNotFoundException("Path does not exist: $modelFile")
        }

        when {
            modelFile.isFile -> {
                return when (modelFile.extension.lowercase()) {
                    "gguf" -> {
                        modelTag = "${modelFile.name} (llama.cpp)"
                        LlamaCppInference()
                    }

                    "task", "litertlm" -> {
                        modelTag = "${modelFile.name} (LiteRT)"
                        LiteRtLmInference(context)
                    }

                    "pte" -> {
                        if (!File(tokenizerPath).isFile) {
                            throw IllegalArgumentException("Please select a tokenizer file for ExecuTorch.")
                        }
                        modelTag = "${modelFile.name} (ExecuTorch)"
                        ExecuTorchInference()
                    }

                    "onnx" -> throw IllegalArgumentException("Please select a directory as the model path if using ONNX.")
                    else -> throw IllegalArgumentException("Unknown model file type: ${modelFile.name}")
                }
            }

            modelFile.isDirectory -> {
                val configFile = File(modelFile, "genai_config.json")
                return if (configFile.exists() && configFile.isFile) {
                    modelTag = "${modelFile.name} (ONNX)"
                    OnnxInference()
                } else {
                    throw IllegalArgumentException("When using ONNX, ensure the path contains a valid genai_config.json file, or select a specific model file for using other engines")
                }
            }

            else -> {
                throw IllegalArgumentException("Path is neither a file nor a directory: $modelPath")
            }
        }
    }
}
