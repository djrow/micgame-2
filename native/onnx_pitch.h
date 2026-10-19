#ifndef ONNX_PITCH_H
#define ONNX_PITCH_H

#include <stddef.h>
#include <stdint.h>

#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#define GD_EXPORT __declspec(dllexport)
#else
#define GD_EXPORT __attribute__((visibility("default"), used))
#endif

#include "gdextension_interface.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Basic Pitch Model Dimensions */
#define BASIC_PITCH_AUDIO_SAMPLES 43844
#define BASIC_PITCH_SAMPLE_RATE 22050
#define BASIC_PITCH_FFT_HOP 256
#define BASIC_PITCH_N_FRAMES 172
#define BASIC_PITCH_N_BINS 88
#define BASIC_PITCH_MIDI_OFFSET 21
#define BASIC_PITCH_CONTOUR_BINS 264

/* Buffer Capacities */
#define BASIC_PITCH_SUMMARY_FLOATS 352
#define BASIC_PITCH_FULL_FLOATS (352 + (BASIC_PITCH_N_FRAMES * BASIC_PITCH_N_BINS * 2)) /* 30,624 floats */

/* Command IDs for Engine Custom Callable */
typedef enum {
	ONNX_CMD_INIT_SESSION = 0,
	ONNX_CMD_RUN_INFERENCE = 1,
	ONNX_CMD_QUERY_STATUS = 2
} OnnxPitchCommandId;

/* Summary Buffer Offsets */
#define ONNX_SUMMARY_TAIL_NOTES_OFFSET 0     /* 88 floats: frames 120..165 */
#define ONNX_SUMMARY_TAIL_ONSETS_OFFSET 88   /* 88 floats: frames 120..165 */
#define ONNX_SUMMARY_FULL_NOTES_OFFSET 176   /* 88 floats: interior frames 8..166 */
#define ONNX_SUMMARY_FULL_ONSETS_OFFSET 264  /* 88 floats: interior frames 8..166 */
#define ONNX_SUMMARY_RAW_MATRICES_OFFSET 352 /* Optional: [172, 88] notes followed by onsets */

/* GDExtension Entry Point */
GD_EXPORT GDExtensionBool onnx_pitch_library_init(
	GDExtensionInterfaceGetProcAddress p_get_proc_address,
	GDExtensionClassLibraryPtr p_library,
	GDExtensionInitialization *r_initialization
);

#ifdef __cplusplus
}
#endif

#endif /* ONNX_PITCH_H */
