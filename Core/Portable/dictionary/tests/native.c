#include "inkflow_dictionary.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

static IFDBytes bytes(const char* text) {
  IFDBytes result = {(const uint8_t*)text, strlen(text)};
  return result;
}

int main(void) {
  char dictionary[] = "---\n...\n你\tni\t100\n";
  IFDResult* spelling = ifd_spelling(bytes(dictionary));
  memset(dictionary, 0, sizeof(dictionary));
  assert(ifd_result_error(spelling).len == 0);
  assert(ifd_result_count(spelling) == 32);
  for (size_t i = 0; i < 32; ++i) {
    IFDBytes name = ifd_result_name(spelling, i);
    IFDBytes data = ifd_result_data(spelling, i);
    assert(name.len > 0 && data.len > 0);
    assert(memchr(name.data, '/', name.len) == NULL);
  }
  assert(ifd_result_name(spelling, 32).len == 0);
  assert(ifd_result_data(spelling, SIZE_MAX).len == 0);

  IFDResult* malformed = ifd_generate(bytes("[]"), NULL, 1, bytes(""));
  assert(ifd_result_error(malformed).len > 0);
  assert(ifd_result_count(malformed) == 0);
  ifd_result_free(malformed);
  assert(ifd_result_count(spelling) == 32);
  ifd_result_free(spelling);

  const uint8_t invalid_utf8[] = {0xff, 0x00};
  IFDBytes invalid = {invalid_utf8, sizeof(invalid_utf8)};
  malformed = ifd_spelling(invalid);
  assert(ifd_result_error(malformed).len > 0);
  ifd_result_free(malformed);
  IFDInput input = {bytes("{}"), bytes("")};
  malformed = ifd_validate(input);
  assert(ifd_result_error(malformed).len > 0);
  ifd_result_free(malformed);
  ifd_result_free(NULL);
  puts("PASS C ABI layout, linking, ownership, errors, and spelling outputs");
  return 0;
}
