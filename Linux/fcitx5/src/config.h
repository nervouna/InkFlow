// Minimum daily-use configuration: ~/.config/fcitx5/conf/inkflow.conf. Option names
// follow the macOS preference keys so a backup's settings map one to one.
#ifndef INKFLOW_FCITX5_CONFIG_H
#define INKFLOW_FCITX5_CONFIG_H
#include <fcitx-config/configuration.h>
#include <fcitx-config/option.h>

#include <string>
#include <vector>

namespace inkflow {

FCITX_CONFIGURATION(
    Config,
    fcitx::Option<int, fcitx::IntConstrain> candidateCount{this, "CandidateCount", "Candidates per page",
                                                           5, fcitx::IntConstrain(3, 9)};
    fcitx::Option<bool> abbreviation{this, "Abbreviation", "Abbreviated pinyin", true};
    fcitx::Option<bool> typoTolerance{this, "TypoTolerance", "Typo tolerance", true};
    fcitx::Option<bool> fuzzyZ{this, "FuzzyZ", "Fuzzy z/zh", false};
    fcitx::Option<bool> fuzzyC{this, "FuzzyC", "Fuzzy c/ch", false};
    fcitx::Option<bool> fuzzyS{this, "FuzzyS", "Fuzzy s/sh", false};
    fcitx::Option<bool> emoji{this, "Emoji", "Emoji suggestions", true};
    fcitx::Option<bool> bracketPaging{this, "BracketPaging", "Page with [ and ]", true};
    fcitx::Option<bool> minusEqualPaging{this, "MinusEqualPaging", "Page with - and =", true};
    fcitx::Option<bool> englishPunctuation{this, "EnglishPunctuation", "English punctuation", false};
    fcitx::Option<bool> cornerQuotes{this, "CornerQuotes", "Corner quotes for braces", true};
    fcitx::Option<bool> middleDot{this, "MiddleDot", "Middle dot for backquote", true};
    fcitx::Option<bool> fullwidthPipe{this, "FullwidthPipe", "Fullwidth pipe", true};
    fcitx::Option<bool> ideographicComma{this, "IdeographicComma", "Ideographic comma for backslash", true};
    fcitx::Option<bool> traditional{this, "Traditional", "Traditional Chinese output", false};
    fcitx::Option<std::vector<std::string>> customPhrases{this, "CustomPhrases",
                                                          "Custom phrases, one code=text per entry"};
    fcitx::Option<std::string> importBackup{this, "ImportBackup",
                                            "Path of a macOS personal backup to import once"};);

}  // namespace inkflow
#endif
