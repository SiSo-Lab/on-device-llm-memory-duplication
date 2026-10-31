package dev.filipfan.polyengineinfer.llamacpp.internal

import android.util.Log
import dev.filipfan.polyengineinfer.api.LlmInferenceOptions
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.withContext
import java.util.concurrent.Executors
import kotlin.concurrent.thread

/**
 * Initial source code:
 * https://github.com/ggml-org/llama.cpp/blob/b6018/examples/llama.android/llama/src/main/java/android/llama/cpp/LLamaAndroid.kt
 */
@Suppress("ktlint:standard:function-naming", "ktlint:standard:backing-property-naming")
internal class LLamaAndroid {
    private val tag: String? = this::class.simpleName

    private val threadLocalState: ThreadLocal<State> = ThreadLocal.withInitial { State.Idle }

    private val runLoop: CoroutineDispatcher = Executors.newSingleThreadExecutor {
        thread(start = false, name = "Llm-RunLoop") {
            Log.d(tag, "Dedicated thread for native code: ${Thread.currentThread().name}")

            // No-op if called more than once.
            System.loadLibrary("llama-android")

            // Set llama log handler to Android
            log_to_android()
            backend_init(false)

            Log.d(tag, system_info())

            it.run()
        }.apply {
            uncaughtExceptionHandler = Thread.UncaughtExceptionHandler { _, exception: Throwable ->
                Log.e(tag, "Unhandled exception", exception)
            }
        }
    }.asCoroutineDispatcher()

    private val recentPromptTokenSize = intArrayOf(-1)

    private external fun log_to_android()
    private external fun load_model(filename: String): Long
    private external fun free_model(model: Long)
    private external fun new_context(model: Long): Long
    private external fun load_lora_adapter(model: Long, path: String): Long
    private external fun set_lora_adapter(context: Long, adapter: Long): Int
    private external fun free_lora_adapter(adapter: Long)
    private external fun free_context(context: Long)
    private external fun backend_init(numa: Boolean)
    private external fun backend_free()
    private external fun new_batch(nTokens: Int, embd: Int, nSeqMax: Int): Long
    private external fun free_batch(batch: Long)
    private external fun new_sampler(topK: Int, topP: Float, temp: Float): Long
    private external fun free_sampler(sampler: Long)
    private external fun bench_model(
        context: Long,
        model: Long,
        batch: Long,
        pp: Int,
        tg: Int,
        pl: Int,
        nr: Int,
    ): String

    private external fun system_info(): String

    private external fun completion_init(
        context: Long,
        batch: Long,
        text: String,
        formatChat: Boolean,
        nLen: Int,
        promptTokenSize: IntArray,
    ): Int

    private external fun completion_loop(
        context: Long,
        batch: Long,
        sampler: Long,
        nLen: Int,
        ncur: IntVar,
    ): String?

    private external fun kv_cache_clear(context: Long)

    suspend fun bench(pp: Int, tg: Int, pl: Int, nr: Int = 1): String = withContext(runLoop) {
        when (val state = threadLocalState.get()) {
            is State.Loaded -> {
                Log.d(tag, "bench(): $state")
                bench_model(state.context, state.model, state.batch, pp, tg, pl, nr)
            }

            else -> throw IllegalStateException("No model loaded")
        }
    }

    suspend fun load(pathToModel: String, options: LlmInferenceOptions) {
        withContext(runLoop) {
            when (threadLocalState.get()) {
                is State.Idle -> {
                    val model = load_model(pathToModel)
                    if (model == 0L) throw IllegalStateException("load_model() failed")

                    val context = new_context(model)
                    if (context == 0L) throw IllegalStateException("new_context() failed")

                    val adapterPathFile = java.io.File("/data/local/tmp/lora_ksm/poly/adapter_path.txt")
                    var loraAdapter = 0L
                    if (adapterPathFile.exists() && adapterPathFile.canRead()) {
                        val adapterPath = adapterPathFile.readText().trim()
                        if (adapterPath.isNotEmpty()) {
                            Log.i(tag, "[LORA_KSM] Poly LoRA adapter path: $adapterPath")
                            loraAdapter = load_lora_adapter(model, adapterPath)
                            if (loraAdapter == 0L) throw IllegalStateException("load_lora_adapter() failed")
                            val ret = set_lora_adapter(context, loraAdapter)
                            Log.i(tag, "[LORA_KSM] set_lora_adapter ret=$ret")
                            if (ret != 0) throw IllegalStateException("set_lora_adapter() failed: $ret")
                        }
                    }

                    val batch = new_batch(options.maxTokens, 0, 1)
                    if (batch == 0L) throw IllegalStateException("new_batch() failed")

                    val sampler = new_sampler(options.topK, options.topP, options.temperature)
                    if (sampler == 0L) throw IllegalStateException("new_sampler() failed")

                    val loraAdapterPathForLog = try {
                        val cfg = java.io.File("/data/local/tmp/lora_ksm/poly/adapter_path.txt")
                        if (cfg.exists() && cfg.canRead()) cfg.readText().trim() else ""
                    } catch (_: Throwable) {
                        ""
                    }

                    if (loraAdapterPathForLog.isNotEmpty()) {
                        Log.i("LORA_KSM", "Poly loaded model with LoRA adapter: model=$pathToModel adapter=$loraAdapterPathForLog")
                    } else {
                        Log.i(tag, "Loaded model without LoRA adapter: model=$pathToModel")
                    }
                    threadLocalState.set(State.Loaded(model, context, batch, sampler, loraAdapter, options))
                }

                else -> throw IllegalStateException("Model already loaded")
            }
        }
    }

    fun send(message: String, formatChat: Boolean = false): Flow<String> = flow {
        when (val state = threadLocalState.get()) {
            is State.Loaded -> {
                val nlen = state.options.maxTokens
                val ncur =
                    IntVar(
                        completion_init(
                            state.context,
                            state.batch,
                            message,
                            formatChat,
                            nlen,
                            recentPromptTokenSize,
                        ),
                    )
                while (ncur.value <= nlen) {
                    val str = completion_loop(state.context, state.batch, state.sampler, nlen, ncur)
                        ?: break
                    emit(str)
                }
                kv_cache_clear(state.context)
            }

            else -> {}
        }
    }.flowOn(runLoop)

    /**
     * Unloads the model and frees resources.
     *
     * This is a no-op if there's no model loaded.
     */
    suspend fun unload() {
        withContext(runLoop) {
            when (val state = threadLocalState.get()) {
                is State.Loaded -> {
                    free_context(state.context)
                    if (state.loraAdapter != 0L) {
                        free_lora_adapter(state.loraAdapter)
                    }
                    free_model(state.model)
                    free_batch(state.batch)
                    free_sampler(state.sampler)

                    recentPromptTokenSize[0] = -1
                    threadLocalState.set(State.Idle)
                }

                else -> {}
            }
        }
    }

    fun getLatestGenerationPromptTokenSize(): Int = recentPromptTokenSize[0]

    companion object {
        private class IntVar(value: Int) {
            @Volatile
            var value: Int = value
                private set

            fun inc() {
                synchronized(this) {
                    value += 1
                }
            }
        }

        private sealed interface State {
            data object Idle : State
            data class Loaded(
                val model: Long,
                val context: Long,
                val batch: Long,
                val sampler: Long,
                val loraAdapter: Long,
                val options: LlmInferenceOptions,
            ) : State
        }

        // Enforce only one instance of Llm.
        private val _instance: LLamaAndroid = LLamaAndroid()

        fun instance(): LLamaAndroid = _instance
    }
}
