#ifndef INKFLOW_DICTIONARY_H
#define INKFLOW_DICTIONARY_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef struct { const uint8_t* data; size_t len; } IFDBytes;
typedef struct { IFDBytes receipt; IFDBytes data; } IFDInput;
typedef struct IFDResult IFDResult;

IFDBytes ifd_catalog(void);
uint32_t ifd_recipe_version(void);
size_t ifd_maximum_source_bytes(void);
IFDResult* ifd_generate(IFDBytes catalog, const IFDInput* inputs, size_t count,
                        IFDBytes corrections);
IFDResult* ifd_spelling(IFDBytes dictionary);
IFDResult* ifd_validate(IFDInput input);
IFDBytes ifd_result_error(const IFDResult* result);
size_t ifd_result_count(const IFDResult* result);
IFDBytes ifd_result_name(const IFDResult* result, size_t index);
IFDBytes ifd_result_data(const IFDResult* result, size_t index);
void ifd_result_free(IFDResult* result);
#ifdef __cplusplus
}
#endif
#endif
