#ifndef INKFLOW_DICTIONARY_H
#define INKFLOW_DICTIONARY_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

/* Experimental in-process preparation ABI; never call on the key-event path.
 * Inputs are borrowed for the call. Nonempty buffers/arrays must point to valid,
 * aligned readable storage; NULL is accepted only for an empty buffer/array.
 * JSON uses the existing catalog and receipt formats. Dictionary/correction
 * buffers are raw bytes, including invalid UTF-8, for normal validation.
 * Each operation returns an owned result, including on validation failure.
 * Output buffers are borrowed until result_free; they are NOT NUL-terminated.
 * Accessors require a live, non-NULL result. Callers must not mutate buffers
 * or free a result while it is being read.
 * Independent calls/results may be used on different threads. No global state,
 * filesystem, network, Rime, or process launching is involved.
 * Rust panics become bridge-panic errors; invalid pointers, allocator aborts,
 * and process crashes are not recoverable. Free every result exactly once.
 */
typedef struct { const uint8_t* data; size_t len; } IFDBytes;
typedef struct { IFDBytes receipt; IFDBytes data; } IFDInput;
typedef struct IFDResult IFDResult;

IFDResult* ifd_generate(IFDBytes catalog, const IFDInput* inputs, size_t count,
                        IFDBytes corrections);
IFDResult* ifd_spelling(IFDBytes dictionary);
IFDResult* ifd_validate(IFDInput input);
/* Empty on success; otherwise JSON {code, source, line}. Failed results have
 * no files. bridge-input/bridge-json report malformed ABI requests. */
IFDBytes ifd_result_error(const IFDResult* result);
size_t ifd_result_count(const IFDResult* result);
/* Out-of-range indices return empty buffers. Names are UTF-8 basenames. */
IFDBytes ifd_result_name(const IFDResult* result, size_t index);
IFDBytes ifd_result_data(const IFDResult* result, size_t index);
void ifd_result_free(IFDResult* result); /* NULL is a no-op. */
#ifdef __cplusplus
}
#endif
#endif
