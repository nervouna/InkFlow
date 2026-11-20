// Generate only the scalar properties used by QualityTextKind.classify and punctuation proof.
// The target's ICU is a build tool; no Unicode data file or library is loaded while typing.
#include <unicode/uchar.h>

#include <fstream>

int main(int argc, char** argv) {
  if (argc != 2) return 1;
  std::ofstream out(argv[1]);
  out.exceptions(std::ios::badbit | std::ios::failbit);
  out << "// Generated Unicode property ranges (Unicode-3.0).\n";
  out << "enum class ScalarKind { Other, Emoji, Symbol };\n";
  out << "constexpr struct { uint32_t last; ScalarKind kind; } scalarRanges[] = {\n";
  auto kind = [](UChar32 c) {
    if (c == 0xfe0f || c == 0x20e3 || u_hasBinaryProperty(c, UCHAR_EMOJI_PRESENTATION)) return 1;
    return ((U_GET_GC_MASK(c) & (U_GC_P_MASK | U_GC_S_MASK)) || u_isUWhiteSpace(c)) ? 2 : 0;
  };
  const char* names[] = {"Other", "Emoji", "Symbol"};
  int previous = kind(0);
  for (UChar32 c = 1; c <= 0x110000; ++c) {
    int current = c == 0x110000 ? -1 : kind(c);
    if (current != previous) {
      out << "  {" << (c - 1) << ", ScalarKind::" << names[previous] << "},\n";
      previous = current;
    }
  }
  out << "};\n";
  out.close();
}
