#ifndef INKFLOW_RIME_NATIVE_H
#define INKFLOW_RIME_NATIVE_H

#ifdef __cplusplus
extern "C" {
#endif

void IFRegisterRimeNativeComponents(void);
int IFPersonalDataSnapshot(const char* root, const char* name, const char* file, int restore);

#ifdef __cplusplus
}
#endif

#endif
