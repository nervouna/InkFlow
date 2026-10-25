#include "InkFlowRimeNative.h"

#include <algorithm>
#include <limits>
#include <tuple>
#include <rime/algo/syllabifier.h>
#include <rime/context.h>
#include <rime/dict/dictionary.h>
#include <rime/dict/user_dictionary.h>
#include <rime/engine.h>
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

// Context properties that carry the input verdicts to the Lua metadata: IsTechnicalInput's, and whether a
// lowercase input is complete normal Pinyin.
const char* const kTechnicalInputProperty = "inkflow_technical_input";
const char* const kPinyinInputProperty = "inkflow_pinyin_input";

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

// An ASCII run of a mixed sentence and its lowercase code in the English user
// dictionary. `commits` is the run's confirmation count there, 0 when it has none.
struct AsciiRun {
  string display;
  string code;
  int commits;
};

class MixedPhrase final : public Phrase {
 public:
  // `learned` is the bucket 0-3 of the sentence's weakest ASCII run, 0 as soon as
  // one run has no personal confirmation. `runs` is every ASCII run of the text.
  MixedPhrase(size_t start, size_t end, const string& text,
              const string& preedit, int learned, const vector<AsciiRun>& runs,
              vector<ComponentSpan> components, vector<size_t> vertices)
      : Phrase(ReadOnlyLanguage(), "mixed_personal_" + std::to_string(learned),
               start, end, New<DictEntry>()),
        components_(std::move(components)) {
    entry_->text = text;
    entry_->preedit = preedit;
    // The English learner reads the runs of a committed sentence from here, as
    // "display<TAB>code" lines; the entry has no dictionary code of its own.
    for (const auto& run : runs)
      entry_->custom_code += run.display + '\t' + run.code + '\n';
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

// A prism key is normal when one of its spellings is neither an abbreviation,
// fuzzy, completion nor typo-correction alias.
bool HasNormalSpelling(Prism& prism, int spelling_id) {
  for (auto spelling = prism.QuerySpelling(spelling_id); !spelling.exhausted();
       spelling.Next()) {
    const auto properties = spelling.properties();
    if (properties.type == kNormalSpelling && !properties.is_correction)
      return true;
  }
  return false;
}

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
      if (match.length == 0 || !HasNormalSpelling(prism, match.value)) continue;
      size_t end = begin + match.length;
      while (end < input.size() && delimiters.find(input[end]) != string::npos)
        ++end;
      edges[start].push_back(end);
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

// Whether `tail` is an unfinished syllable: the start of some key that has a
// normal spelling, such as `n` of `ni` or `zh` of `zhong`.
bool BeginsNormalSpelling(Prism& prism, const string& tail) {
  vector<Prism::Match> keys;
  prism.ExpandSearch(tail, &keys, 0);
  return std::any_of(keys.begin(), keys.end(), [&](const Prism::Match& key) {
    return HasNormalSpelling(prism, key.value);
  });
}

// An input of 4 or more ASCII letters that is not complete normal syllables
// optionally followed by one unfinished final syllable, as `macos` and
// `deepseek` are not but `email` (e mai l) and `chin` (chi n) are. The same
// native normal-spelling evidence as rule 9: abbreviations, fuzzy pairs and
// typo aliases never make an input look like Pinyin. `reachable` is
// ReachableFromStart over the input's NormalEdges.
bool IsTechnicalInput(const string& input, const vector<bool>& reachable, Prism& prism) {
  if (input.size() < 4 || reachable.back()) return false;
  for (size_t start = 0; start < input.size(); ++start) {
    if (reachable[start] && BeginsNormalSpelling(prism, input.substr(start)))
      return false;
  }
  return true;
}

struct PersonalMatch {
  size_t start;
  size_t end;
  an<DictEntry> entry;
};

// Confirmation counts of the personal edges that can carry a sentence, keyed by
// input span and exact display.
using Learned = map<std::tuple<size_t, size_t, string>, int>;

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
    const bool bounded = segment.HasAnyTagIn(tags_) && !input.empty() &&
        max_input_length_ > 0 && input.size() <= static_cast<size_t>(max_input_length_) &&
        input.size() <= static_cast<size_t>(std::numeric_limits<int>::max()) &&
        segment.end >= segment.start && input.size() == segment.end - segment.start &&
        pinyin_ && pinyin_->loaded();
    // Both verdicts read one NormalEdges of the input, which the personal lookup below reuses.
    Edges normal;
    string technical;
    string pinyin;
    if (bounded && std::all_of(input.begin(), input.end(), IsLetter)) {
      normal = NormalEdges(input, *pinyin_->prism(), delimiters_);
      const auto reachable = ReachableFromStart(normal);
      if (IsTechnicalInput(input, reachable, *pinyin_->prism())) technical = input;
      // Capitals are explicit English intent (rule 9), so only lowercase input is Pinyin here.
      if (reachable.back() && !HasUppercase(input)) pinyin = input;
    }
    PublishInput(kTechnicalInputProperty, technical);
    PublishInput(kPinyinInputProperty, pinyin);
    if (!bounded || !mixed_ || !mixed_->loaded() || !personal_ || !personal_->loaded())
      return nullptr;

    const auto matches = FindPersonalMatches(input);
    if (matches.empty()) return nullptr;
    if (normal.empty()) normal = NormalEdges(input, *pinyin_->prism(), delimiters_);
    auto context = normal;
    map<string, bool> admitted_runs;
    AddPublicContext(input, &context, &admitted_runs);
    const auto left = ReachableFromStart(context);
    const auto right = ReachableToEnd(context);
    map<pair<size_t, size_t>, an<StaticSlice>> slices;
    set<string> emitted;
    // Only edges that can carry a sentence count as personal evidence for runs
    // another edge's sentence passes through.
    vector<PersonalMatch> usable;
    Learned learned;
    for (const auto& match : matches) {
      if (CutsNormalSpelling(match, normal, left, right)) continue;
      usable.push_back(match);
      learned.emplace(std::make_tuple(match.start, match.end, match.entry->text),
                      match.entry->commit_count);
    }
    auto result = New<FifoTranslation>();
    for (const auto& match : usable) {
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
                                     *prefix, *suffix, learned, &admitted_runs);
      if (candidate && emitted.insert(candidate->text()).second)
        result->Append(candidate);
    }
    return result->exhausted() ? nullptr : result;
  }

 private:
  // The English ranking metadata (inkflow_input_coverage.lua) reads these context
  // properties in the same composition: each holds the input when that input is
  // technical (or lowercase complete Pinyin), otherwise it is empty. Naming the
  // input keeps a stale value from ever matching another one.
  void PublishInput(const char* property, const string& value) {
    Context* context = engine_ ? engine_->context() : nullptr;
    if (context && context->get_property(property) != value)
      context->set_property(property, value);
  }

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
                               const Learned& learned, map<string, bool>* admitted) {
    vector<ComponentSpan> components;
    vector<size_t> all_vertices{offset};
    string preedit;
    string public_run;
    // A public run is as personal as its span: it counts only when it is whole
    // public English entries on an edge with a confirmation.
    size_t run_start = 0, run_end = 0;
    bool run_whole = true;
    vector<AsciiRun> runs;
    const auto finish_run = [&]() {
      if (!PublicRun(public_run, admitted)) return false;
      int commits = 0;
      const auto found = learned.find(std::make_tuple(run_start, run_end, public_run));
      if (run_whole && found != learned.end()) commits = found->second;
      runs.push_back({public_run, Lowercase(public_run), commits});
      public_run.clear();
      return true;
    };
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
        runs.push_back({entry.text, Lowercase(input.substr(cursor, end - cursor)),
                        match.entry->commit_count});
      }
      // Validate complete public ASCII runs, including adjacent native entries.
      for (char c : personal ? string() : entry.text) {
        if (IsLetter(c)) {
          if (public_run.empty()) { run_start = cursor; run_whole = true; }
          if (origin != Origin::PublicEnglish) run_whole = false;
          public_run.push_back(c);
          run_end = end;
        } else if (!public_run.empty() && !finish_run()) {
          return nullptr;
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
    if (!public_run.empty() && !finish_run()) return nullptr;
    if (!has_personal || !has_chinese || cursor != input.size()) return nullptr;
    int learned_bucket = 3;
    for (const auto& run : runs)
      learned_bucket = std::min(learned_bucket, run.commits);
    return New<MixedPhrase>(offset, offset + cursor, sentence.text(), preedit,
                            learned_bucket, runs, std::move(components),
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
