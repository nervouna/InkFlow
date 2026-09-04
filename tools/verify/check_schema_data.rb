#!/usr/bin/env ruby

require "json"
require "yaml"

repo_root = File.expand_path("../..", __dir__)

def fail_check(message)
  warn "schema verification failed: #{message}"
  exit 1
end

def load_yaml(path)
  YAML.safe_load(File.read(path, encoding: "UTF-8"), aliases: true)
rescue Psych::Exception => error
  fail_check("#{path}: #{error.message}")
end

def load_dictionary(path)
  content = File.read(path, encoding: "UTF-8")
  marker = /^\.\.\.\s*$/
  marker_match = content.match(marker)
  fail_check("#{path}: missing dictionary header terminator") unless marker_match

  header_text = content[0...marker_match.end(0)]
  body_text = content[marker_match.end(0)..]
  header = YAML.safe_load(header_text, aliases: true)
  [header, body_text]
rescue Psych::Exception => error
  fail_check("#{path}: #{error.message}")
end

schema_directories = {
  "source" => File.join(repo_root, "schemas", "source"),
  "test" => File.join(repo_root, "schemas", "test")
}

schemas_by_id = {}
dictionary_entries = {}

schema_directories.each do |kind, directory|
  schema_paths = Dir.glob(File.join(directory, "*.schema.yaml")).sort
  dictionary_paths = Dir.glob(File.join(directory, "*.dict.yaml")).sort
  fail_check("#{kind} schema set is empty") if schema_paths.empty?
  fail_check("#{kind} dictionary set is empty") if dictionary_paths.empty?

  dictionary_names = dictionary_paths.to_h do |path|
    header, body = load_dictionary(path)
    name = header.fetch("name", nil)
    expected_name = File.basename(path, ".dict.yaml")
    fail_check("#{path}: name must be #{expected_name}") unless name == expected_name
    fail_check("#{path}: version is required") unless header["version"].is_a?(String)
    fail_check("#{path}: sort is required") unless header["sort"].is_a?(String)
    unless header["columns"] == %w[text code weight]
      fail_check("#{path}: columns must be text, code, weight")
    end

    seen_entries = {}
    entries = body.lines.filter_map.with_index(1) do |line, line_number|
      stripped = line.strip
      next if stripped.empty? || stripped.start_with?("#")

      fields = line.chomp.split("\t", -1)
      fail_check("#{path}:#{line_number}: expected tab-separated text and code") if fields.length < 2
      fail_check("#{path}:#{line_number}: text and code must be non-empty") if fields[0].empty? || fields[1].empty?
      fail_check("#{path}:#{line_number}: weight must be an integer") if fields[2] && fields[2] !~ /\A\d+\z/

      entry_key = fields.first(2)
      fail_check("#{path}:#{line_number}: duplicate text/code entry") if seen_entries.key?(entry_key)
      seen_entries[entry_key] = true
      fields
    end
    fail_check("#{path}: dictionary body is empty") if entries.empty?
    dictionary_entries[[kind, name]] = entries.map { |fields| fields.first(2) }
    [name, path]
  end

  schema_paths.each do |path|
    document = load_yaml(path)
    schema = document.fetch("schema", {})
    schema_id = schema["schema_id"]
    expected_id = File.basename(path, ".schema.yaml")
    fail_check("#{path}: schema_id must be #{expected_id}") unless schema_id == expected_id
    fail_check("#{path}: schema version is required") unless schema["version"].is_a?(String)
    dictionary = document.dig("translator", "dictionary")
    fail_check("#{path}: translator dictionary is required") unless dictionary.is_a?(String)
    fail_check("#{path}: dictionary #{dictionary} is missing in #{kind}") unless dictionary_names.key?(dictionary)
    fail_check("duplicate schema_id #{schema_id}") if schemas_by_id.key?(schema_id)
    schemas_by_id[schema_id] = {
      "kind" => kind,
      "dictionary" => dictionary,
      "document" => document
    }
  end

  default_path = File.join(directory, "default.yaml")
  default_document = load_yaml(default_path)
  listed_schemas = default_document.fetch("schema_list", []).map { |entry| entry["schema"] }
  local_schema_ids = schema_paths.map { |path| File.basename(path, ".schema.yaml") }
  fail_check("#{default_path}: schema_list must exactly name local schemas") unless listed_schemas == local_schema_ids
end

unexpected_schema_paths = Dir.glob(File.join(repo_root, "**", "*.{schema,dict}.yaml"), File::FNM_EXTGLOB).reject do |path|
  path.start_with?(schema_directories["source"] + File::SEPARATOR) ||
    path.start_with?(schema_directories["test"] + File::SEPARATOR) ||
    path.start_with?(File.join(repo_root, "third_party") + File::SEPARATOR) ||
    path.start_with?(File.join(repo_root, "build") + File::SEPARATOR)
end
fail_check("schema copies exist outside canonical/test roots: #{unexpected_schema_paths.join(', ')}") unless unexpected_schema_paths.empty?

transcript_paths = Dir.glob(File.join(repo_root, "testdata", "transcripts", "*.json")).sort
fail_check("no deterministic transcript found") if transcript_paths.empty?

transcript_paths.each do |path|
  transcript = JSON.parse(File.read(path, encoding: "UTF-8"))
  fail_check("#{path}: unsupported formatVersion") unless transcript["formatVersion"] == 1
  schema_id = transcript["schemaId"]
  schema_record = schemas_by_id[schema_id]
  fail_check("#{path}: schemaId must reference schemas/test") unless schema_record && schema_record["kind"] == "test"
  if schema_record["document"].dig("translator", "enable_user_dict") != false
    fail_check("#{path}: deterministic schema must disable the user dictionary")
  end

  actions = transcript["actions"]
  fail_check("#{path}: actions must be non-empty") unless actions.is_a?(Array) && !actions.empty?
  key_sequence = actions.filter_map { |action| action["key"] if action["type"] == "key" }.join
  fail_check("#{path}: canonical transcript must type nihao") unless key_sequence == "nihao"
  last_action = actions.last
  expected_commit = last_action.dig("expect", "commit")
  unless last_action["type"] == "selectCandidate" && last_action["index"] == 0
    fail_check("#{path}: final action must select candidate zero")
  end
  fail_check("#{path}: final action must commit 你好") unless expected_commit == "你好"
  test_entries = dictionary_entries[[schema_record["kind"], schema_record["dictionary"]]]
  unless test_entries&.include?([expected_commit, key_sequence])
    fail_check("#{path}: test dictionary does not contain the expected text/code pair")
  end
rescue JSON::ParserError => error
  fail_check("#{path}: #{error.message}")
end

puts "PASS schema data and deterministic transcripts"
