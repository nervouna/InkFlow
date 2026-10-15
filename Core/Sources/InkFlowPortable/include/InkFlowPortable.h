#include "../../../Portable/include/inkflow_rime.h"

/* The native personal-data snapshot the sandboxed worker's restore runs on closed staged databases.
 * It is not part of the engine ABI: libinkflow_rime.a carries the InkFlowRimeNative sources it comes
 * from (restore only; the worker exports through ifr_personal_export). */
#ifdef __cplusplus
extern "C" {
#endif
int IFPersonalDataSnapshot(const char* root, const char* name, const char* file, int restore);
#ifdef __cplusplus
}
#endif
