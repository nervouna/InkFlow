#include "InkFlowRimeNative.h"

#include <algorithm>
#include <limits>
#include <rime/algo/syllabifier.h>
#include <rime/dict/dictionary.h>
#include <rime/dict/user_dictionary.h>
#include <rime/gear/poet.h>
#include <rime/language.h>
#include <rime/registry.h>
#include <rime/schema.h>
#include <rime/segmentation.h>
#include <rime/translator.h>

namespace {
using namespace rime;

bool IsLetter(char c) {
  return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
}

bool HasUppercase(const string& text) {
  return std::any_of(text.begin(), text.end(),
                     [](char c) { return c >= 'A' && c <= 'Z'; });
}

string Lowercase(string text) {
  for (char& c : text) {
    if (c >= 'A' && c <= 'Z') c = static_cast<char>(c + ('a' - 'A'));
  }
  return text;
}

bool IsPublicEnglish(const string& text) {
  return !text.empty() && std::all_of(text.begin(), text.end(), IsLetter);
}

enum class Origin { Chinese, PublicEnglish, PersonalEnglish };

struct ComponentSpan {
  Origin origin;
  size_t start;
  size_t end;
  DictEntry entry;
  vector<size_t> syllables;
};

class MixedSyllabifier final : public PhraseSyllabifier {
 public:
  explicit MixedSyllabifier(vector<size_t> vertices)
      : vertices_(std::move(vertices)) {}

  Spans Syllabify(const Phrase*) override {
    Spans spans;
    for (size_t vertex : vertices_) spans.AddVertex(vertex);
    return spans;
  }

 private:
  vector<size_t> vertices_;
};

class MixedPhrase final : public Phrase {
 public:
  MixedPhrase(size_t start, size_t end, const string& text,
              const string& preedit, int commits,
              vector<ComponentSpan> components, vector<size_t> vertices)
      : Phrase(ReadOnlyLanguage(), "mixed_personal_" + std::to_string(std::min(3, commits)),
               start, end, New<DictEntry>()),
        components_(std::move(components)) {
    entry_->text = text;
    entry_->preedit = preedit;
    // A multilingual sentence has no shared native syllable-code namespace.
    // This language has no Memory/store. Keep it non-null because librime-lua's
    // Phrase.lang_name binding dereferences the language pointer.
    set_syllabifier(New<MixedSyllabifier>(std::move(vertices)));
    set_quality(-0.5);
  }

  const vector<ComponentSpan>& components() const { return components_; }

 private:
  static const Language* ReadOnlyLanguage() {
    static const Language language("inkflow_mixed_readonly");
    return &language;
  }
  // Retain actual lexical provenance even though this candidate is read-only.
  vector<ComponentSpan> components_;
};

// Recover the selected dictionary code's positions from the native graph.
// No spelling rules or synthetic syllable IDs are introduced here.
bool RecoverSpans(const SyllableGraph& graph, const Code& code, size_t index,
                  size_t position, size_t end, vector<size_t>* vertices) {
  if (index == code.size()) return position == end;
  const auto source = graph.edges.find(position);
  if (source == graph.edges.end()) return false;
  for (auto edge = source->second.rbegin(); edge != source->second.rend(); ++edge) {
    if (edge->first > end || edge->second.find(code[index]) == edge->second.end())
      continue;
    vertices->push_back(edge->first);
    if (RecoverSpans(graph, code, index + 1, edge->first, end, vertices))
      return true;
    vertices->pop_back();
  }
  return false;
}

using Edges = vector<vector<size_t>>;

// Enumerate all normal lexical spans in the uncut input. Syllabifier's final
// graph prunes competing paths, so admission reads the same native prism API
// before that pruning. Delimiters follow Syllabifier's consumption convention.
Edges NormalEdges(const string& input, Prism& prism, const string& delimiters) {
  Edges edges(input.size() + 1);
  for (size_t start = 0; start < input.size(); ++start) {
    size_t begin = start;
    while (begin < input.size() && delimiters.find(input[begin]) != string::npos)
      ++begin;
    vector<Prism::Match> matches;
    prism.CommonPrefixSearch(input.substr(begin), &matches);
    for (const auto& match : matches) {
      if (match.length == 0) continue;
      for (auto spelling = prism.QuerySpelling(match.value);
           !spelling.exhausted(); spelling.Next()) {
        const auto properties = spelling.properties();
        if (properties.type != kNormalSpelling || properties.is_correction)
          continue;
        size_t end = begin + match.length;
        while (end < input.size() && delimiters.find(input[end]) != string::npos)
          ++end;
        edges[start].push_back(end);
        break;
      }
    }
  }
  return edges;
}

vector<bool> ReachableFromStart(const Edges& edges) {
  vector<bool> reachable(edges.size(), false);
  reachable[0] = true;
  for (size_t start = 0; start < edges.size(); ++start) {
    if (!reachable[start]) continue;
    for (size_t end : edges[start]) reachable[end] = true;
  }
  return reachable;
}

vector<bool> ReachableToEnd(const Edges& edges) {
  vector<bool> reachable(edges.size(), false);
  reachable.back() = true;
  for (size_t start = edges.size() - 1; start > 0; --start) {
    for (size_t end : edges[start - 1]) {
      if (reachable[end]) reachable[start - 1] = true;
    }
  }
  return reachable;
}

struct PersonalMatch {
  size_t start;
  size_t end;
  an<DictEntry> entry;
};

struct StaticSlice {
  size_t start = 0;
  size_t end = 0;
  SyllableGraph syllables;
  WordGraph words;
  bool covered = false;
};

class MixedPersonalTranslator final : public Translator {
 public:
  explicit MixedPersonalTranslator(const Ticket& ticket) : Translator(ticket) {
    if (!ticket.schema) return;
    Config* config = ticket.schema->config();
    config->GetInt("mixed_personal/max_input_length", &max_input_length_);
    config->GetInt("mixed/max_homophones", &max_homophones_);
    max_homophones_ = std::max(1, max_homophones_);
    config->GetString("speller/delimiter", &delimiters_);
    formatter_.Load(config->GetList("mixed/preedit_format"));
    if (auto configured = config->GetList("mixed/tags")) {
      tags_.clear();
      for (const auto& item : *configured) {
        if (auto value = As<ConfigValue>(item)) tags_.push_back(value->str());
      }
    } else {
      config->GetString("mixed/tag", &tags_.front());
    }
    if (auto factory = Dictionary::Require("dictionary")) {
      mixed_.reset(factory->Create(Ticket(ticket.schema, "mixed")));
      pinyin_.reset(factory->Create(Ticket(ticket.schema, "translator")));
      if (mixed_) mixed_->Load();
      if (pinyin_) pinyin_->Load();
    }
    if (auto factory = UserDictionary::Require("user_dictionary")) {
      personal_.reset(factory->Create(Ticket(ticket.schema, "english")));
      if (personal_) personal_->Load();
    }
    // This reader lives for the translator's entire lifetime. In particular,
    // Query never destroys it or touches transactions: UserDictionary's native
    // destructor commits on schema/session teardown, just like existing Memory.
    poet_ = std::make_unique<Poet>(nullptr, config);
  }

  an<Translation> Query(const string& input, const Segment& segment) override {
    if (!segment.HasAnyTagIn(tags_) || input.empty() || max_input_length_ <= 0 ||
        input.size() > static_cast<size_t>(max_input_length_) ||
        input.size() > static_cast<size_t>(std::numeric_limits<int>::max()) ||
        segment.end < segment.start || input.size() != segment.end - segment.start ||
        !mixed_ || !mixed_->loaded() || !pinyin_ || !pinyin_->loaded() ||
        !personal_ || !personal_->loaded())
      return nullptr;

    const auto matches = FindPersonalMatches(input);
    if (matches.empty()) return nullptr;
    const auto normal = NormalEdges(input, *pinyin_->prism(), delimiters_);
    auto context = normal;
    map<string, bool> admitted_runs;
    AddPublicContext(input, &context, &admitted_runs);
    const auto left = ReachableFromStart(context);
    const auto right = ReachableToEnd(context);
    map<pair<size_t, size_t>, an<StaticSlice>> slices;
    set<string> emitted;
    auto result = New<FifoTranslation>();
    for (const auto& match : matches) {
      if (CutsNormalSpelling(match, normal, left, right)) continue;
      auto prefix = Slice(input, 0, match.start, &slices);
      auto suffix = Slice(input, match.end, input.size(), &slices);
      if (!prefix->covered || !suffix->covered) continue;
      WordGraph words = prefix->words;
      words.insert(suffix->words.begin(), suffix->words.end());
      auto personal = New<DictEntry>(*match.entry);
      personal->code.clear();
      words[static_cast<int>(match.start)][static_cast<int>(match.end)].push_back(personal);
      auto sentence = poet_->MakeSentence(words, input.size(), "");
      if (!sentence || sentence->end() != input.size()) continue;
      auto candidate = MakeCandidate(input, segment.start, match, *sentence,
                                     *prefix, *suffix, &admitted_runs);
      if (candidate && emitted.insert(candidate->text()).second)
        result->Append(candidate);
    }
    return result->exhausted() ? nullptr : result;
  }

 private:
  vector<PersonalMatch> FindPersonalMatches(const string& input) {
    vector<PersonalMatch> matches;
    const string lower = Lowercase(input);
    map<string, bool> pinyin_codes;
    for (size_t start = 0; start < input.size(); ++start) {
      for (size_t end = start + 1; end <= input.size(); ++end) {
        if (!IsLetter(input[end - 1])) break;
        const string code = lower.substr(start, end - start);
        UserDictEntryIterator prefix;
        personal_->LookupWords(&prefix, code, true, 1);
        if (prefix.exhausted()) break;
        if (start == 0 && end == input.size()) continue;
        if (!HasUppercase(input.substr(start, end - start))) {
          if (code.size() == 1) continue;
          auto known = pinyin_codes.find(code);
          if (known == pinyin_codes.end()) {
            const auto normal = NormalEdges(code, *pinyin_->prism(), delimiters_);
            known = pinyin_codes.emplace(code, ReachableFromStart(normal).back()).first;
          }
          if (known->second) continue;
        }
        UserDictEntryIterator exact;
        personal_->LookupWords(&exact, code, false);
        set<string> displays;
        for (; !exact.exhausted(); exact.Next()) {
          const auto entry = exact.Peek();
          string stored_code = entry->custom_code;
          while (!stored_code.empty() && stored_code.back() == ' ')
            stored_code.pop_back();
          if (stored_code != code || entry->commit_count <= 0 || entry->text.empty() ||
              !std::all_of(entry->text.begin(), entry->text.end(),
                           [](unsigned char c) { return c >= 33 && c <= 126; }) ||
              !displays.insert(entry->text).second)
            continue;
          matches.push_back({start, end, entry});
        }
      }
    }
    return matches;
  }

  bool PublicRun(const string& text, map<string, bool>* cache) {
    const auto known = cache->find(text);
    if (known != cache->end()) return known->second;
    DictEntryIterator entries;
    mixed_->LookupWords(&entries, text, false);
    bool admitted = false;
    for (; !entries.exhausted(); entries.Next()) {
      if (entries.Peek()->text == text) { admitted = true; break; }
    }
    cache->emplace(text, admitted);
    return admitted;
  }

  void AddPublicContext(const string& input, Edges* context,
                        map<string, bool>* admitted) {
    for (size_t start = 0; start < input.size(); ++start) {
      vector<Prism::Match> matches;
      mixed_->prism()->CommonPrefixSearch(input.substr(start), &matches);
      for (const auto& match : matches) {
        if (match.length == 0) continue;
        DictEntryIterator entries;
        mixed_->LookupWords(&entries, input.substr(start, match.length), false);
        for (; !entries.exhausted(); entries.Next()) {
          const auto entry = entries.Peek();
          if (IsPublicEnglish(entry->text) && PublicRun(entry->text, admitted)) {
            (*context)[start].push_back(start + match.length);
            break;
          }
        }
      }
    }
  }

  static bool CutsNormalSpelling(const PersonalMatch& match, const Edges& normal,
                                 const vector<bool>& left,
                                 const vector<bool>& right) {
    for (size_t start = 0; start < normal.size(); ++start) {
      for (size_t end : normal[start]) {
        if ((start < match.start && end > match.start && left[start]) ||
            (start < match.end && end > match.end && right[end]))
          return true;
      }
    }
    return false;
  }

  an<StaticSlice> Slice(const string& input, size_t start, size_t end,
                        map<pair<size_t, size_t>, an<StaticSlice>>* cache) {
    const auto key = std::make_pair(start, end);
    auto found = cache->find(key);
    if (found != cache->end()) return found->second;
    auto slice = New<StaticSlice>();
    slice->start = start;
    slice->end = end;
    cache->emplace(key, slice);
    if (start == end) { slice->covered = true; return slice; }
    Syllabifier syllabifier(delimiters_, false, false);
    const auto covered = syllabifier.BuildSyllableGraph(
        input.substr(start, end - start), *mixed_->prism(), &slice->syllables);
    if (covered != static_cast<int>(end - start)) return slice;
    slice->covered = true;
    for (const auto& source : slice->syllables.edges) {
      auto found_entries = mixed_->Lookup(slice->syllables, source.first);
      if (!found_entries) continue;
      for (auto& target : *found_entries) {
        auto& entries = slice->words[static_cast<int>(start + source.first)]
                                    [static_cast<int>(start + target.first)];
        while (!target.second.exhausted() &&
               entries.size() < static_cast<size_t>(max_homophones_)) {
          auto entry = target.second.Peek();
          // Apply the personal boundary constraint before native homophone
          // pruning. Otherwise e.g. English "sang" can hide the valid 桑 path.
          const bool ascii_neighbor = !entry->text.empty() &&
              ((end < input.size() && target.first == end - start &&
                IsLetter(entry->text.back())) ||
               (start > 0 && source.first == 0 && IsLetter(entry->text.front())));
          if (entry->IsExactMatch() && !ascii_neighbor) entries.push_back(entry);
          target.second.Next();
        }
      }
    }
    return slice;
  }

  an<Candidate> MakeCandidate(const string& input, size_t offset,
                               const PersonalMatch& match, const Sentence& sentence,
                               const StaticSlice& prefix, const StaticSlice& suffix,
                               map<string, bool>* admitted) {
    vector<ComponentSpan> components;
    vector<size_t> all_vertices{offset};
    string preedit;
    string public_run;
    bool has_chinese = false;
    bool has_personal = false;
    size_t cursor = 0;
    const auto& entries = sentence.components();
    for (size_t index = 0; index < entries.size(); ++index) {
      const auto& entry = entries[index];
      const size_t end = cursor + sentence.word_lengths()[index];
      if (end > input.size()) return nullptr;
      const bool personal = cursor == match.start && end == match.end;
      const Origin origin = personal ? Origin::PersonalEnglish :
                            IsPublicEnglish(entry.text) ? Origin::PublicEnglish : Origin::Chinese;
      if (personal) {
        if (has_personal || (index > 0 && !entries[index - 1].text.empty() &&
                            IsLetter(entries[index - 1].text.back())) ||
            (index + 1 < entries.size() && !entries[index + 1].text.empty() &&
             IsLetter(entries[index + 1].text.front())))
          return nullptr;
        has_personal = true;
      }
      // Validate complete public ASCII runs, including adjacent native entries.
      for (char c : personal ? string() : entry.text) {
        if (IsLetter(c)) public_run.push_back(c);
        else if (!public_run.empty()) {
          if (!PublicRun(public_run, admitted)) return nullptr;
          public_run.clear();
        }
        if (static_cast<unsigned char>(c) >= 128) has_chinese = true;
      }
      if (personal && !public_run.empty()) return nullptr;
      vector<size_t> vertices{cursor};
      if (personal) {
        vertices.push_back(end);
      } else {
        const auto& slice = end <= match.start ? prefix : suffix;
        if (cursor < slice.start || end > slice.end) return nullptr;
        vertices = {cursor - slice.start};
        if (!RecoverSpans(slice.syllables, entry.code, 0, cursor - slice.start,
                          end - slice.start, &vertices)) return nullptr;
        for (size_t& vertex : vertices) vertex += slice.start;
      }
      for (size_t i = 1; i < vertices.size(); ++i) {
        if (!preedit.empty()) preedit += ' ';
        string spelling = input.substr(vertices[i - 1], vertices[i] - vertices[i - 1]);
        if (origin == Origin::Chinese) formatter_.Apply(&spelling);
        preedit += spelling;
        all_vertices.push_back(offset + vertices[i]);
      }
      for (size_t& vertex : vertices) vertex += offset;
      components.push_back({origin, offset + cursor, offset + end, entry,
                            std::move(vertices)});
      cursor = end;
    }
    if (!public_run.empty() && !PublicRun(public_run, admitted)) return nullptr;
    if (!has_personal || !has_chinese || cursor != input.size()) return nullptr;
    return New<MixedPhrase>(offset, offset + cursor, sentence.text(), preedit,
                            match.entry->commit_count, std::move(components),
                            std::move(all_vertices));
  }

  int max_input_length_ = 64;
  int max_homophones_ = 1;
  string delimiters_ = " '";
  vector<string> tags_{"abc"};
  the<Dictionary> mixed_;
  the<Dictionary> pinyin_;
  the<UserDictionary> personal_;
  the<Poet> poet_;
  Projection formatter_;
};
}  // namespace

extern "C" void IFRegisterRimeNativeComponents(void) {
  rime::Registry::instance().Register(
      "inkflow_mixed_personal", new rime::Component<MixedPersonalTranslator>);
}
