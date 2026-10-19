#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#define GD_EXPORT __declspec(dllexport)
#else
#define GD_EXPORT __attribute__((visibility("default"), used))
#endif

#include "gdextension_interface.h"
#include "onnxruntime_c_api.h"
#include "onnx_pitch.h"

static void onnx_memzero(void *dst, size_t n) {
	uint8_t *p = (uint8_t *)dst;
	for (size_t i = 0; i < n; ++i) {
		p[i] = 0;
	}
}

static void onnx_memcpy(void *dst, const void *src, size_t n) {
	uint8_t *d = (uint8_t *)dst;
	const uint8_t *s = (const uint8_t *)src;
	for (size_t i = 0; i < n; ++i) {
		d[i] = s[i];
	}
}

/* GDExtension interface function pointers */
static GDExtensionClassLibraryPtr g_library = NULL;
static GDExtensionInterfaceVariantDestroy gd_variant_destroy = NULL;
static GDExtensionInterfaceVariantNewCopy gd_variant_new_copy = NULL;
static GDExtensionInterfaceVariantNewNil gd_variant_new_nil = NULL;
static GDExtensionInterfaceVariantGetType gd_variant_get_type = NULL;
static GDExtensionInterfaceVariantCall gd_variant_call = NULL;
static GDExtensionInterfaceGetVariantFromTypeConstructor gd_get_variant_from_type = NULL;
static GDExtensionInterfaceGetVariantGetInternalPtrFunc gd_get_internal_ptr_func = NULL;
static GDExtensionInterfaceStringNameNewWithLatin1Chars gd_string_name_new_latin1 = NULL;
static GDExtensionInterfaceVariantGetPtrDestructor gd_variant_get_ptr_destructor = NULL;
static GDExtensionInterfaceGlobalGetSingleton gd_global_get_singleton = NULL;
static GDExtensionInterfaceCallableCustomCreate2 gd_callable_custom_create2 = NULL;
static GDExtensionInterfacePackedByteArrayOperatorIndexConst gd_packed_byte_array_index_const = NULL;
static GDExtensionInterfacePackedFloat32ArrayOperatorIndex gd_packed_float32_array_index = NULL;
static GDExtensionInterfacePackedFloat32ArrayOperatorIndexConst gd_packed_float32_array_index_const = NULL;

static GDExtensionVariantGetInternalPtrFunc gd_int_internal_ptr = NULL;
static GDExtensionVariantGetInternalPtrFunc gd_byte_array_internal_ptr = NULL;
static GDExtensionVariantGetInternalPtrFunc gd_float32_array_internal_ptr = NULL;
static GDExtensionVariantFromTypeConstructorFunc gd_variant_from_int = NULL;

/* ONNX Runtime state */
static const OrtApi *g_ort = NULL;
static OrtEnv *g_env = NULL;
static OrtSession *g_session = NULL;
static OrtMemoryInfo *g_mem_info = NULL;
static char *g_input_name = NULL;
static int g_ort_initialized = 0;
static float g_input_buffer[BASIC_PITCH_AUDIO_SAMPLES];

typedef const OrtApiBase *(ORT_API_CALL *OrtGetApiBaseFunc)(void);

static int ensure_ort_loaded(void) {
	if (g_ort != NULL) {
		return 1;
	}

	OrtGetApiBaseFunc get_api_base = NULL;

#if defined(_WIN32)
	HMODULE hmod = GetModuleHandleA("onnxruntime.dll");
	if (!hmod) {
		hmod = LoadLibraryA("bin/windows/onnxruntime.dll");
	}
	if (!hmod) {
		hmod = LoadLibraryA("onnxruntime.dll");
	}
	if (hmod) {
		get_api_base = (OrtGetApiBaseFunc)(void *)GetProcAddress(hmod, "OrtGetApiBase");
	}
#else
	get_api_base = &OrtGetApiBase;
#endif

	if (!get_api_base) {
		return 0;
	}

	const OrtApiBase *base = get_api_base();
	if (!base || !base->GetApi) {
		return 0;
	}

	/* API version 17 is supported across ONNX Runtime 1.17.x .. 1.21+ without console warnings */
	for (uint32_t ver = 17; ver >= 14; --ver) {
		g_ort = base->GetApi(ver);
		if (g_ort != NULL) {
			break;
		}
	}

	return (g_ort != NULL) ? 1 : 0;
}

static void cleanup_ort_session(void) {
	if (g_ort) {
		if (g_input_name) {
			OrtAllocator *allocator = NULL;
			OrtStatus *st = g_ort->GetAllocatorWithDefaultOptions(&allocator);
			if (st == NULL && allocator) {
				OrtStatus *free_st = g_ort->AllocatorFree(allocator, g_input_name);
				if (free_st) {
					g_ort->ReleaseStatus(free_st);
				}
			} else if (st) {
				g_ort->ReleaseStatus(st);
			}
			g_input_name = NULL;
		}
		if (g_session) {
			g_ort->ReleaseSession(g_session);
			g_session = NULL;
		}
		if (g_mem_info) {
			g_ort->ReleaseMemoryInfo(g_mem_info);
			g_mem_info = NULL;
		}
		if (g_env) {
			g_ort->ReleaseEnv(g_env);
			g_env = NULL;
		}
	}
	g_ort_initialized = 0;
}

static int init_ort_session_from_bytes(const uint8_t *model_bytes, size_t model_size) {
	if (!model_bytes || model_size < 64) {
		return -1;
	}
	if (!ensure_ort_loaded()) {
		return -2;
	}

	cleanup_ort_session();

	OrtStatus *status = NULL;
	status = g_ort->CreateEnv(ORT_LOGGING_LEVEL_WARNING, "micgame_basic_pitch", &g_env);
	if (status != NULL) {
		g_ort->ReleaseStatus(status);
		return -3;
	}

	OrtSessionOptions *opts = NULL;
	status = g_ort->CreateSessionOptions(&opts);
	if (status != NULL) {
		g_ort->ReleaseStatus(status);
		cleanup_ort_session();
		return -4;
	}

	/* Optimize graph and use 2 intra-op threads for low-latency mobile + desktop inference */
	status = g_ort->SetIntraOpNumThreads(opts, 2);
	if (status) {
		g_ort->ReleaseStatus(status);
	}
	status = g_ort->SetSessionGraphOptimizationLevel(opts, ORT_ENABLE_ALL);
	if (status) {
		g_ort->ReleaseStatus(status);
	}

	status = g_ort->CreateSessionFromArray(g_env, (const void *)model_bytes, model_size, opts, &g_session);
	g_ort->ReleaseSessionOptions(opts);
	if (status != NULL || g_session == NULL) {
		if (status) {
			g_ort->ReleaseStatus(status);
		}
		cleanup_ort_session();
		return -5;
	}

	status = g_ort->CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &g_mem_info);
	if (status != NULL || g_mem_info == NULL) {
		if (status) {
			g_ort->ReleaseStatus(status);
		}
		cleanup_ort_session();
		return -6;
	}

	OrtAllocator *allocator = NULL;
	status = g_ort->GetAllocatorWithDefaultOptions(&allocator);
	if (status == NULL && allocator != NULL) {
		status = g_ort->SessionGetInputName(g_session, 0, allocator, &g_input_name);
		if (status != NULL) {
			g_ort->ReleaseStatus(status);
			g_input_name = NULL;
		}
	} else if (status != NULL) {
		g_ort->ReleaseStatus(status);
	}

	g_ort_initialized = 1;
	return 1;
}

static int run_ort_inference(const float *audio_in, int64_t sample_count, float *out_floats, int64_t out_capacity) {
	if (!g_ort_initialized || !g_ort || !g_session || !g_mem_info || !audio_in || !out_floats) {
		return -1;
	}
	if (out_capacity < BASIC_PITCH_SUMMARY_FLOATS) {
		return -2;
	}

	if (sample_count >= BASIC_PITCH_AUDIO_SAMPLES) {
		int64_t offset = sample_count - BASIC_PITCH_AUDIO_SAMPLES;
		onnx_memcpy(g_input_buffer, audio_in + offset, sizeof(float) * BASIC_PITCH_AUDIO_SAMPLES);
	} else if (sample_count > 0) {
		int64_t pad = BASIC_PITCH_AUDIO_SAMPLES - sample_count;
		onnx_memzero(g_input_buffer, sizeof(float) * (size_t)pad);
		onnx_memcpy(g_input_buffer + pad, audio_in, sizeof(float) * (size_t)sample_count);
	} else {
		onnx_memzero(g_input_buffer, sizeof(g_input_buffer));
	}

	int64_t input_shape[3] = { 1, BASIC_PITCH_AUDIO_SAMPLES, 1 };
	OrtValue *input_tensor = NULL;
	OrtStatus *status = g_ort->CreateTensorWithDataAsOrtValue(
			g_mem_info,
			(void *)g_input_buffer,
			sizeof(g_input_buffer),
			input_shape,
			3,
			ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT,
			&input_tensor);
	if (status != NULL || input_tensor == NULL) {
		if (status) {
			g_ort->ReleaseStatus(status);
		}
		return -3;
	}

	const char *input_names[1] = {
		g_input_name ? g_input_name : "serving_default_input_2:0"
	};
	const OrtValue *input_vals[1] = { input_tensor };
	const char *output_names[2] = {
		"StatefulPartitionedCall:1", /* notes: [1, 172, 88] */
		"StatefulPartitionedCall:2"  /* onsets: [1, 172, 88] */
	};
	OrtValue *output_vals[2] = { NULL, NULL };

	status = g_ort->Run(
			g_session,
			NULL,
			input_names,
			input_vals,
			1,
			output_names,
			2,
			output_vals);

	g_ort->ReleaseValue(input_tensor);

	if (status != NULL || output_vals[0] == NULL || output_vals[1] == NULL) {
		if (status) {
			g_ort->ReleaseStatus(status);
		}
		if (output_vals[0]) {
			g_ort->ReleaseValue(output_vals[0]);
		}
		if (output_vals[1]) {
			g_ort->ReleaseValue(output_vals[1]);
		}
		return -4;
	}

	float *notes_data = NULL;
	float *onsets_data = NULL;
	OrtStatus *st0 = g_ort->GetTensorMutableData(output_vals[0], (void **)&notes_data);
	if (st0) {
		g_ort->ReleaseStatus(st0);
	}
	OrtStatus *st1 = g_ort->GetTensorMutableData(output_vals[1], (void **)&onsets_data);
	if (st1) {
		g_ort->ReleaseStatus(st1);
	}

	if (!notes_data || !onsets_data) {
		g_ort->ReleaseValue(output_vals[0]);
		g_ort->ReleaseValue(output_vals[1]);
		return -5;
	}

	onnx_memzero(out_floats, sizeof(float) * BASIC_PITCH_SUMMARY_FLOATS);

	/* 1. Live streaming receptive field tail frames: [120 .. 165] (N_FRAMES - 52 .. N_FRAMES - 6) */
	int tail_start = BASIC_PITCH_N_FRAMES - 52;
	int tail_end = BASIC_PITCH_N_FRAMES - 6;
	for (int f = tail_start; f < tail_end; ++f) {
		const float *note_row = notes_data + (f * BASIC_PITCH_N_BINS);
		const float *onset_row = onsets_data + (f * BASIC_PITCH_N_BINS);
		for (int b = 0; b < BASIC_PITCH_N_BINS; ++b) {
			if (note_row[b] > out_floats[ONNX_SUMMARY_TAIL_NOTES_OFFSET + b]) {
				out_floats[ONNX_SUMMARY_TAIL_NOTES_OFFSET + b] = note_row[b];
			}
			if (onset_row[b] > out_floats[ONNX_SUMMARY_TAIL_ONSETS_OFFSET + b]) {
				out_floats[ONNX_SUMMARY_TAIL_ONSETS_OFFSET + b] = onset_row[b];
			}
		}
	}

	/* 2. Full-window summary across valid interior frames [8 .. 166] */
	for (int f = 8; f < BASIC_PITCH_N_FRAMES - 6; ++f) {
		const float *note_row = notes_data + (f * BASIC_PITCH_N_BINS);
		const float *onset_row = onsets_data + (f * BASIC_PITCH_N_BINS);
		for (int b = 0; b < BASIC_PITCH_N_BINS; ++b) {
			if (note_row[b] > out_floats[ONNX_SUMMARY_FULL_NOTES_OFFSET + b]) {
				out_floats[ONNX_SUMMARY_FULL_NOTES_OFFSET + b] = note_row[b];
			}
			if (onset_row[b] > out_floats[ONNX_SUMMARY_FULL_ONSETS_OFFSET + b]) {
				out_floats[ONNX_SUMMARY_FULL_ONSETS_OFFSET + b] = onset_row[b];
			}
		}
	}

	/* 3. Optional full [172, 88] notes and onsets matrices if caller passed a 30,624-float buffer */
	if (out_capacity >= BASIC_PITCH_FULL_FLOATS) {
		size_t matrix_floats = (size_t)(BASIC_PITCH_N_FRAMES * BASIC_PITCH_N_BINS);
		onnx_memcpy(out_floats + ONNX_SUMMARY_RAW_MATRICES_OFFSET, notes_data, sizeof(float) * matrix_floats);
		onnx_memcpy(out_floats + ONNX_SUMMARY_RAW_MATRICES_OFFSET + matrix_floats, onsets_data, sizeof(float) * matrix_floats);
	}

	g_ort->ReleaseValue(output_vals[0]);
	g_ort->ReleaseValue(output_vals[1]);
	return 1;
}

static void set_return_int(GDExtensionVariantPtr r_return, int64_t val) {
	if (gd_variant_destroy && gd_variant_from_int) {
		gd_variant_destroy(r_return);
		gd_variant_from_int(r_return, &val);
	}
}

static void onnx_callable_call(
		void *callable_userdata,
		const GDExtensionConstVariantPtr *p_args,
		GDExtensionInt p_argument_count,
		GDExtensionVariantPtr r_return,
		GDExtensionCallError *r_error) {
	(void)callable_userdata;
	if (r_error) {
		r_error->error = GDEXTENSION_CALL_OK;
		r_error->argument = 0;
		r_error->expected = 0;
	}

	if (p_argument_count < 1 || !gd_int_internal_ptr) {
		set_return_int(r_return, -100);
		return;
	}

	if (gd_variant_get_type(p_args[0]) != GDEXTENSION_VARIANT_TYPE_INT) {
		set_return_int(r_return, -101);
		return;
	}

	int64_t cmd = *(int64_t *)gd_int_internal_ptr((GDExtensionVariantPtr)p_args[0]);

	if (cmd == ONNX_CMD_INIT_SESSION) {
		/* Command 0: Initialize ONNX session from PackedByteArray
		 * Args: (0, model_bytes: PackedByteArray, byte_count: int)
		 */
		if (p_argument_count < 3) {
			set_return_int(r_return, -102);
			return;
		}
		if (gd_variant_get_type(p_args[1]) != GDEXTENSION_VARIANT_TYPE_PACKED_BYTE_ARRAY ||
				gd_variant_get_type(p_args[2]) != GDEXTENSION_VARIANT_TYPE_INT) {
			set_return_int(r_return, -103);
			return;
		}
		int64_t byte_count = *(int64_t *)gd_int_internal_ptr((GDExtensionVariantPtr)p_args[2]);
		if (byte_count <= 0) {
			set_return_int(r_return, -104);
			return;
		}
		GDExtensionTypePtr byte_arr_ptr = gd_byte_array_internal_ptr((GDExtensionVariantPtr)p_args[1]);
		const uint8_t *raw_bytes = gd_packed_byte_array_index_const(byte_arr_ptr, 0);
		int rc = init_ort_session_from_bytes(raw_bytes, (size_t)byte_count);
		set_return_int(r_return, (int64_t)rc);
		return;
	} else if (cmd == ONNX_CMD_RUN_INFERENCE) {
		/* Command 1: Run ONNX Basic Pitch inference
		 * Args: (1, audio_samples: PackedFloat32Array, sample_count: int, out_template: PackedFloat32Array, out_count: int)
		 * Returns: populated PackedFloat32Array
		 */
		if (p_argument_count < 5) {
			set_return_int(r_return, -202);
			return;
		}
		if (gd_variant_get_type(p_args[1]) != GDEXTENSION_VARIANT_TYPE_PACKED_FLOAT32_ARRAY ||
				gd_variant_get_type(p_args[2]) != GDEXTENSION_VARIANT_TYPE_INT ||
				gd_variant_get_type(p_args[3]) != GDEXTENSION_VARIANT_TYPE_PACKED_FLOAT32_ARRAY ||
				gd_variant_get_type(p_args[4]) != GDEXTENSION_VARIANT_TYPE_INT) {
			set_return_int(r_return, -203);
			return;
		}

		int64_t sample_count = *(int64_t *)gd_int_internal_ptr((GDExtensionVariantPtr)p_args[2]);
		int64_t out_count = *(int64_t *)gd_int_internal_ptr((GDExtensionVariantPtr)p_args[4]);
		if (sample_count <= 0 || out_count < BASIC_PITCH_SUMMARY_FLOATS) {
			set_return_int(r_return, -204);
			return;
		}

		GDExtensionTypePtr in_arr_ptr = gd_float32_array_internal_ptr((GDExtensionVariantPtr)p_args[1]);
		const float *audio_ptr = gd_packed_float32_array_index_const(in_arr_ptr, 0);

		/* Copy out_template into r_return and write directly into its detached float buffer */
		gd_variant_destroy(r_return);
		gd_variant_new_copy(r_return, p_args[3]);
		GDExtensionTypePtr out_arr_ptr = gd_float32_array_internal_ptr(r_return);
		float *out_ptr = gd_packed_float32_array_index(out_arr_ptr, 0);

		int rc = run_ort_inference(audio_ptr, sample_count, out_ptr, out_count);
		if (rc != 1) {
			set_return_int(r_return, (int64_t)rc);
		}
		return;
	} else if (cmd == ONNX_CMD_QUERY_STATUS) {
		/* Command 2: Query status (1 = session ready, 0 = not initialized) */
		set_return_int(r_return, (int64_t)g_ort_initialized);
		return;
	}

	set_return_int(r_return, -999);
}

static void register_engine_meta_callable(void) {
	if (!gd_string_name_new_latin1 || !gd_global_get_singleton || !gd_callable_custom_create2 ||
			!gd_get_variant_from_type || !gd_variant_call || !gd_variant_destroy) {
		return;
	}

	GDExtensionVariantFromTypeConstructorFunc variant_from_obj =
			gd_get_variant_from_type(GDEXTENSION_VARIANT_TYPE_OBJECT);
	GDExtensionVariantFromTypeConstructorFunc variant_from_sn =
			gd_get_variant_from_type(GDEXTENSION_VARIANT_TYPE_STRING_NAME);
	GDExtensionVariantFromTypeConstructorFunc variant_from_callable =
			gd_get_variant_from_type(GDEXTENSION_VARIANT_TYPE_CALLABLE);
	GDExtensionPtrDestructor sn_destructor =
			gd_variant_get_ptr_destructor ? gd_variant_get_ptr_destructor(GDEXTENSION_VARIANT_TYPE_STRING_NAME) : NULL;
	GDExtensionPtrDestructor callable_destructor =
			gd_variant_get_ptr_destructor ? gd_variant_get_ptr_destructor(GDEXTENSION_VARIANT_TYPE_CALLABLE) : NULL;

	if (!variant_from_obj || !variant_from_sn || !variant_from_callable) {
		return;
	}

	uint64_t sn_engine[4] = { 0 };
	gd_string_name_new_latin1(sn_engine, "Engine", 0);
	GDExtensionObjectPtr engine_obj = gd_global_get_singleton(sn_engine);
	if (sn_destructor) {
		sn_destructor(sn_engine);
	}
	if (!engine_obj) {
		return;
	}

	uint64_t custom_callable[4] = { 0 };
	GDExtensionCallableCustomInfo2 cinfo;
	onnx_memzero(&cinfo, sizeof(cinfo));
	cinfo.callable_userdata = NULL;
	cinfo.token = g_library;
	cinfo.object_id = 0;
	cinfo.call_func = onnx_callable_call;
	gd_callable_custom_create2(custom_callable, &cinfo);

	uint64_t sn_set_meta[4] = { 0 };
	uint64_t sn_meta_key[4] = { 0 };
	gd_string_name_new_latin1(sn_set_meta, "set_meta", 0);
	gd_string_name_new_latin1(sn_meta_key, "onnx_pitch_native", 0);

	uint64_t var_engine[8] = { 0 };
	uint64_t var_key[8] = { 0 };
	uint64_t var_callable[8] = { 0 };
	uint64_t var_ret[8] = { 0 };

	variant_from_obj(var_engine, &engine_obj);
	variant_from_sn(var_key, sn_meta_key);
	variant_from_callable(var_callable, custom_callable);

	const GDExtensionConstVariantPtr call_args[2] = {
		(GDExtensionConstVariantPtr)var_key,
		(GDExtensionConstVariantPtr)var_callable
	};
	GDExtensionCallError call_err;
	onnx_memzero(&call_err, sizeof(call_err));

	gd_variant_call(var_engine, sn_set_meta, call_args, 2, var_ret, &call_err);

	gd_variant_destroy(var_ret);
	gd_variant_destroy(var_callable);
	gd_variant_destroy(var_key);
	gd_variant_destroy(var_engine);

	if (callable_destructor) {
		callable_destructor(custom_callable);
	}
	if (sn_destructor) {
		sn_destructor(sn_meta_key);
		sn_destructor(sn_set_meta);
	}
}

static void unregister_engine_meta_callable(void) {
	if (!gd_string_name_new_latin1 || !gd_global_get_singleton ||
			!gd_get_variant_from_type || !gd_variant_call || !gd_variant_destroy) {
		return;
	}

	GDExtensionVariantFromTypeConstructorFunc variant_from_obj =
			gd_get_variant_from_type(GDEXTENSION_VARIANT_TYPE_OBJECT);
	GDExtensionVariantFromTypeConstructorFunc variant_from_sn =
			gd_get_variant_from_type(GDEXTENSION_VARIANT_TYPE_STRING_NAME);
	GDExtensionPtrDestructor sn_destructor =
			gd_variant_get_ptr_destructor ? gd_variant_get_ptr_destructor(GDEXTENSION_VARIANT_TYPE_STRING_NAME) : NULL;

	if (!variant_from_obj || !variant_from_sn) {
		return;
	}

	uint64_t sn_engine[4] = { 0 };
	gd_string_name_new_latin1(sn_engine, "Engine", 0);
	GDExtensionObjectPtr engine_obj = gd_global_get_singleton(sn_engine);
	if (sn_destructor) {
		sn_destructor(sn_engine);
	}
	if (!engine_obj) {
		return;
	}

	uint64_t sn_remove_meta[4] = { 0 };
	uint64_t sn_meta_key[4] = { 0 };
	gd_string_name_new_latin1(sn_remove_meta, "remove_meta", 0);
	gd_string_name_new_latin1(sn_meta_key, "onnx_pitch_native", 0);

	uint64_t var_engine[8] = { 0 };
	uint64_t var_key[8] = { 0 };
	uint64_t var_ret[8] = { 0 };

	variant_from_obj(var_engine, &engine_obj);
	variant_from_sn(var_key, sn_meta_key);

	const GDExtensionConstVariantPtr call_args[1] = {
		(GDExtensionConstVariantPtr)var_key
	};
	GDExtensionCallError call_err;
	onnx_memzero(&call_err, sizeof(call_err));

	gd_variant_call(var_engine, sn_remove_meta, call_args, 1, var_ret, &call_err);

	gd_variant_destroy(var_ret);
	gd_variant_destroy(var_key);
	gd_variant_destroy(var_engine);

	if (sn_destructor) {
		sn_destructor(sn_meta_key);
		sn_destructor(sn_remove_meta);
	}
}

static void initialize_onnx_pitch_module(void *p_userdata, GDExtensionInitializationLevel p_level) {
	(void)p_userdata;
	if (p_level == GDEXTENSION_INITIALIZATION_SCENE) {
		register_engine_meta_callable();
	}
}

static void deinitialize_onnx_pitch_module(void *p_userdata, GDExtensionInitializationLevel p_level) {
	(void)p_userdata;
	if (p_level == GDEXTENSION_INITIALIZATION_SCENE) {
		unregister_engine_meta_callable();
		cleanup_ort_session();
	}
}

GD_EXPORT GDExtensionBool onnx_pitch_library_init(
		GDExtensionInterfaceGetProcAddress p_get_proc_address,
		GDExtensionClassLibraryPtr p_library,
		GDExtensionInitialization *r_initialization) {
	if (!p_get_proc_address || !r_initialization) {
		return 0;
	}

	g_library = p_library;

	gd_variant_destroy = (GDExtensionInterfaceVariantDestroy)(void *)p_get_proc_address("variant_destroy");
	gd_variant_new_copy = (GDExtensionInterfaceVariantNewCopy)(void *)p_get_proc_address("variant_new_copy");
	gd_variant_new_nil = (GDExtensionInterfaceVariantNewNil)(void *)p_get_proc_address("variant_new_nil");
	gd_variant_get_type = (GDExtensionInterfaceVariantGetType)(void *)p_get_proc_address("variant_get_type");
	gd_variant_call = (GDExtensionInterfaceVariantCall)(void *)p_get_proc_address("variant_call");
	gd_get_variant_from_type = (GDExtensionInterfaceGetVariantFromTypeConstructor)(void *)p_get_proc_address("get_variant_from_type_constructor");
	gd_get_internal_ptr_func = (GDExtensionInterfaceGetVariantGetInternalPtrFunc)(void *)p_get_proc_address("variant_get_ptr_internal_getter");
	gd_string_name_new_latin1 = (GDExtensionInterfaceStringNameNewWithLatin1Chars)(void *)p_get_proc_address("string_name_new_with_latin1_chars");
	gd_variant_get_ptr_destructor = (GDExtensionInterfaceVariantGetPtrDestructor)(void *)p_get_proc_address("variant_get_ptr_destructor");
	gd_global_get_singleton = (GDExtensionInterfaceGlobalGetSingleton)(void *)p_get_proc_address("global_get_singleton");
	gd_callable_custom_create2 = (GDExtensionInterfaceCallableCustomCreate2)(void *)p_get_proc_address("callable_custom_create2");
	gd_packed_byte_array_index_const = (GDExtensionInterfacePackedByteArrayOperatorIndexConst)(void *)p_get_proc_address("packed_byte_array_operator_index_const");
	gd_packed_float32_array_index = (GDExtensionInterfacePackedFloat32ArrayOperatorIndex)(void *)p_get_proc_address("packed_float32_array_operator_index");
	gd_packed_float32_array_index_const = (GDExtensionInterfacePackedFloat32ArrayOperatorIndexConst)(void *)p_get_proc_address("packed_float32_array_operator_index_const");

	if (gd_get_internal_ptr_func) {
		gd_int_internal_ptr = gd_get_internal_ptr_func(GDEXTENSION_VARIANT_TYPE_INT);
		gd_byte_array_internal_ptr = gd_get_internal_ptr_func(GDEXTENSION_VARIANT_TYPE_PACKED_BYTE_ARRAY);
		gd_float32_array_internal_ptr = gd_get_internal_ptr_func(GDEXTENSION_VARIANT_TYPE_PACKED_FLOAT32_ARRAY);
	}
	if (gd_get_variant_from_type) {
		gd_variant_from_int = gd_get_variant_from_type(GDEXTENSION_VARIANT_TYPE_INT);
	}

	r_initialization->minimum_initialization_level = GDEXTENSION_INITIALIZATION_SCENE;
	r_initialization->userdata = NULL;
	r_initialization->initialize = initialize_onnx_pitch_module;
	r_initialization->deinitialize = deinitialize_onnx_pitch_module;

	return 1;
}
