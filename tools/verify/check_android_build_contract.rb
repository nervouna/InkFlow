#!/usr/bin/env ruby

require "json"
require "rexml/document"

module InkFlow
  module AndroidBuildContract
    ANDROID_NAMESPACE = "http://schemas.android.com/apk/res/android"
    IME_SERVICE = "io.damao.inkflow.ime.InkFlowInputMethodService"
    IME_ACTION = "android.view.InputMethod"
    IME_METADATA = "android.view.im"
    BACKUP_DOMAINS = %w[
      root
      file
      database
      sharedpref
      external
      device_root
      device_file
      device_database
      device_sharedpref
    ].freeze

    CATALOG_LOCK_MAPPING = {
      "agp" => "androidGradlePluginVersion",
      "compile-sdk" => "compileSdk",
      "target-sdk" => "targetSdk",
      "min-sdk" => "minSdk",
      "ndk" => "ndkVersion",
      "cmake" => "cmakeVersion",
    }.freeze

    class Violation < StandardError; end

    module_function

    def verify_catalog(lock_json, catalog_toml)
      android = android_lock(lock_json)
      versions = catalog_versions(catalog_toml)

      CATALOG_LOCK_MAPPING.each do |catalog_key, lock_key|
        expected = android.fetch(lock_key).to_s
        actual = versions[catalog_key]
        assert(actual == expected,
               "Android catalog #{catalog_key.inspect} is #{actual.inspect}, expected #{expected.inspect}")
      end
      true
    end

    def verify_artifacts(
      lock_json:,
      app_metadata:,
      cxx_model_json:,
      cmake_index_json:,
      manifest_xml:,
      resource_table:,
      input_method_path:,
      input_method_xml:,
      data_extraction_rules_path:,
      data_extraction_rules_xml:
    )
      android = android_lock(lock_json)
      verify_app_metadata(android, app_metadata)
      verify_cxx_model(android, cxx_model_json)
      verify_cmake_index(android, cmake_index_json)
      references = verify_manifest(android, manifest_xml)
      verify_resource_binding(
        reference: references.fetch(:input_method),
        resource_table: resource_table,
        resource_name: "xml/input_method",
        inspected_path: input_method_path,
        label: "InkFlow IME metadata",
      )
      verify_resource_binding(
        reference: references.fetch(:data_extraction_rules),
        resource_table: resource_table,
        resource_name: "xml/data_extraction_rules",
        inspected_path: data_extraction_rules_path,
        label: "InkFlow application dataExtractionRules",
      )
      verify_input_method(input_method_xml)
      verify_data_extraction_rules(data_extraction_rules_xml)
      true
    end

    def android_lock(lock_json)
      JSON.parse(lock_json).fetch("android")
    rescue JSON::ParserError, KeyError => error
      raise Violation, "invalid Android toolchain lock: #{error.message}"
    end
    private_class_method :android_lock

    def catalog_versions(catalog_toml)
      section = nil
      versions = {}
      catalog_toml.each_line do |raw_line|
        line = raw_line.sub(/\s+#.*\z/, "").strip
        next if line.empty?
        if (section_match = line.match(/\A\[(.+)\]\z/))
          section = section_match[1]
          next
        end
        next unless section == "versions"
        match = line.match(/\A([a-z0-9-]+)\s*=\s*"([^"]+)"\z/)
        next unless match
        key = match[1]
        raise Violation, "duplicate Android catalog version #{key.inspect}" if versions.key?(key)
        versions[key] = match[2]
      end
      versions
    end
    private_class_method :catalog_versions

    def verify_app_metadata(android, properties_text)
      properties = parse_properties(properties_text)
      expected = android.fetch("androidGradlePluginVersion").to_s
      actual = properties["androidGradlePluginVersion"]
      assert(actual == expected,
             "APK AGP metadata is #{actual.inspect}, expected #{expected.inspect}")
    end
    private_class_method :verify_app_metadata

    def parse_properties(text)
      text.each_line.each_with_object({}) do |raw_line, result|
        line = raw_line.strip
        next if line.empty? || line.start_with?("#", "!")
        key, value = line.split("=", 2)
        next unless value
        raise Violation, "duplicate property #{key.inspect}" if result.key?(key)
        result[key] = value
      end
    end
    private_class_method :parse_properties

    def verify_cxx_model(android, model_json)
      model = JSON.parse(model_json)
      variant = model.fetch("variant")
      module_model = variant.fetch("module")
      expected_agp = android.fetch("androidGradlePluginVersion").to_s

      assert(model.dig("info", "name") == "arm64-v8a",
             "active CXX model ABI is not arm64-v8a")
      assert(model.fetch("abiPlatformVersion").to_s == android.fetch("minSdk").to_s,
             "active CXX model API does not match minSdk")
      assert(variant.fetch("validAbiList") == ["arm64-v8a"],
             "active CXX model does not contain exactly the arm64-v8a ABI")
      assert(variant.fetch("buildTargetSet") == ["inkflow_android_jni"],
             "active CXX model does not build exactly the JNI closure target")
      assert(variant.fetch("buildSystemArgumentList").include?("-DANDROID_STL=c++_static"),
             "active CXX model does not use c++_static")
      assert(variant.fetch("stlType") == "c++_static",
             "active CXX model resolved STL is not c++_static")
      assert(module_model.fetch("ndkVersion").to_s == android.fetch("ndkVersion").to_s,
             "active CXX model NDK does not match toolchains.lock.json")
      assert(module_model.dig("cmake", "cmakeVersionFromDsl").to_s ==
               android.fetch("cmakeVersion").to_s,
             "active CXX model CMake DSL version does not match toolchains.lock.json")
      assert(model.fetch("fullConfigurationHashKey").include?("- AGP: #{expected_agp}."),
             "active CXX model AGP does not match toolchains.lock.json")
    rescue JSON::ParserError, KeyError => error
      raise Violation, "invalid active CXX model: #{error.message}"
    end
    private_class_method :verify_cxx_model

    def verify_cmake_index(android, index_json)
      index = JSON.parse(index_json)
      actual = %w[major minor patch].map { |part| index.dig("cmake", "version", part) }
      expected = android.fetch("cmakeVersion").split(".").map(&:to_i)
      assert(actual == expected,
             "CMake File API reports #{actual.join('.')}, expected #{expected.join('.')}")
    rescue JSON::ParserError, KeyError => error
      raise Violation, "invalid CMake File API index: #{error.message}"
    end
    private_class_method :verify_cmake_index

    def verify_manifest(android, manifest_xml)
      manifest = parse_xml(manifest_xml, "release manifest")
      assert(manifest.name == "manifest", "release manifest has the wrong root element")
      assert(android_attribute(manifest, "compileSdkVersion") == android.fetch("compileSdk").to_s,
             "release APK compileSdk does not match toolchains.lock.json")
      assert(manifest.attributes["package"] == "io.damao.inkflow",
             "release APK package is not io.damao.inkflow")

      permission_nodes = manifest.elements.to_a("*").select do |element|
        element.name.start_with?("uses-permission")
      end
      assert(permission_nodes.empty?, "release APK unexpectedly declares a permission")

      uses_sdk = manifest.elements.to_a("uses-sdk")
      assert(uses_sdk.length == 1, "release manifest must contain exactly one uses-sdk")
      assert(android_attribute(uses_sdk.first, "minSdkVersion") == android.fetch("minSdk").to_s,
             "release APK minSdk does not match toolchains.lock.json")
      assert(android_attribute(uses_sdk.first, "targetSdkVersion") == android.fetch("targetSdk").to_s,
             "release APK targetSdk does not match toolchains.lock.json")

      applications = manifest.elements.to_a("application")
      assert(applications.length == 1, "release manifest must contain exactly one application")
      application = applications.first
      %w[allowBackup fullBackupContent usesCleartextTraffic].each do |name|
        assert(android_attribute(application, name) == "false",
               "release application must set android:#{name}=\"false\"")
      end
      data_extraction_rules = android_attribute(application, "dataExtractionRules")
      assert(!data_extraction_rules.to_s.empty?,
             "release application must reference data-extraction rules")

      services = application.elements.to_a("service").select do |service|
        android_attribute(service, "name") == IME_SERVICE
      end
      assert(services.length == 1, "release manifest must contain exactly one InkFlow IME service")
      service = services.first
      assert(android_attribute(service, "permission") == "android.permission.BIND_INPUT_METHOD",
             "InkFlow IME service must require BIND_INPUT_METHOD")
      assert(android_attribute(service, "exported") == "true",
             "InkFlow IME service must be exported")

      actions = service.elements.to_a("intent-filter/action").map do |action|
        android_attribute(action, "name")
      end
      assert(actions.include?(IME_ACTION), "InkFlow IME service is missing its InputMethod action")
      metadata = service.elements.to_a("meta-data").select do |entry|
        android_attribute(entry, "name") == IME_METADATA
      end
      assert(metadata.length == 1 && !android_attribute(metadata.first, "resource").to_s.empty?,
             "InkFlow IME service is missing its input-method metadata resource")
      {
        input_method: android_attribute(metadata.first, "resource"),
        data_extraction_rules: data_extraction_rules,
      }
    end
    private_class_method :verify_manifest

    def verify_resource_binding(reference:, resource_table:, resource_name:, inspected_path:, label:)
      reference_match = reference.match(/\A@(?:ref\/)?(0x[0-9a-fA-F]+)\z/)
      assert(reference_match, "#{label} is not a compiled resource reference")
      referenced_id = reference_match[1].downcase

      entries = []
      current_entry = nil
      resource_table.each_line do |line|
        if (resource_match = line.match(/^\s*resource\s+(0x[0-9a-fA-F]+)\s+(\S+)\s*$/))
          current_entry = nil
          if resource_match[2] == resource_name
            current_entry = {id: resource_match[1].downcase, value_rows: []}
            entries << current_entry
          end
        elsif current_entry &&
            (value_match = line.match(/^\s*\(([^)]*)\)\s+(.+?)\s*$/))
          current_entry[:value_rows] << [value_match[1], value_match[2]]
        end
      end

      assert(entries.length == 1,
             "APK resource table must contain exactly one #{resource_name} entry")
      entry = entries.first
      assert(entry[:id] == referenced_id,
             "#{label} does not reference #{resource_name}")
      resolved_path = inspected_path.strip
      expected_row = [["", "(file) #{resolved_path} type=XML"]]
      assert(entry[:value_rows] == expected_row,
             "#{resource_name} must contain exactly the inspected default XML value")
    end
    private_class_method :verify_resource_binding

    def verify_input_method(input_method_xml)
      input_method = parse_xml(input_method_xml, "packaged input-method XML")
      assert(input_method.name == "input-method", "packaged input-method XML has the wrong root")
      assert(android_attribute(input_method, "supportsSwitchingToNextInputMethod") == "true",
             "packaged input method must support switching to the next input method")
      subtypes = input_method.elements.to_a("subtype")
      assert(subtypes.length == 1, "packaged input method must contain exactly one subtype")
      subtype = subtypes.first
      assert(android_attribute(subtype, "languageTag") == "zh-Hans-CN",
             "packaged input-method languageTag must be zh-Hans-CN")
      assert(android_attribute(subtype, "imeSubtypeMode") == "keyboard",
             "packaged input-method subtype mode must be keyboard")
    end
    private_class_method :verify_input_method

    def verify_data_extraction_rules(data_extraction_rules_xml)
      rules = parse_xml(data_extraction_rules_xml, "packaged data-extraction rules")
      assert(rules.name == "data-extraction-rules",
             "packaged data-extraction rules have the wrong root")
      assert(rules.attributes.empty?,
             "packaged data-extraction rules root must not have attributes")

      sections = element_children(rules, "data-extraction-rules")
      section_names = sections.map(&:name)
      assert(section_names.sort == %w[cloud-backup device-transfer],
             "packaged data-extraction rules must contain only cloud-backup and device-transfer")

      %w[cloud-backup device-transfer].each do |section_name|
        section = sections.find { |candidate| candidate.name == section_name }
        assert(section.attributes.empty?,
               "#{section_name} must not have attributes")
        excludes = element_children(section, section_name)
        assert(excludes.length == BACKUP_DOMAINS.length &&
                 excludes.all? { |element| element.name == "exclude" },
               "#{section_name} must contain only the nine deny-all excludes")

        actual = excludes.map do |exclude|
          attributes = exclude.attributes.to_a
          assert(attributes.all? { |attribute| attribute.prefix.empty? } &&
                   attributes.map(&:name).sort == %w[domain path],
                 "#{section_name} excludes must contain only domain and path")
          assert(exclude.children.empty?,
                 "#{section_name} excludes must be empty elements")
          [exclude.attributes["domain"], exclude.attributes["path"]]
        end
        expected = BACKUP_DOMAINS.map { |domain| [domain, "."] }
        assert(actual.sort == expected.sort,
               "#{section_name} must exclude path '.' for every backup domain exactly once")
      end
    end
    private_class_method :verify_data_extraction_rules

    def element_children(element, label)
      element.children.each_with_object([]) do |child, children|
        if child.is_a?(REXML::Element)
          children << child
        elsif child.instance_of?(REXML::Text) && child.value.strip.empty?
          next
        else
          raise Violation, "#{label} contains an unexpected XML node"
        end
      end
    end
    private_class_method :element_children

    def parse_xml(text, label)
      REXML::Document.new(text).root || raise(Violation, "#{label} has no root element")
    rescue REXML::ParseException => error
      raise Violation, "invalid #{label}: #{error.message}"
    end
    private_class_method :parse_xml

    def android_attribute(element, name)
      element.attributes.get_attribute_ns(ANDROID_NAMESPACE, name)&.value
    end
    private_class_method :android_attribute

    def assert(condition, message)
      raise Violation, message unless condition
    end
    private_class_method :assert
  end
end

if $PROGRAM_NAME == __FILE__
  mode = ARGV.shift
  begin
    case mode
    when "catalog"
      abort "usage: #{File.basename($PROGRAM_NAME)} catalog LOCK CATALOG" unless ARGV.length == 2
      InkFlow::AndroidBuildContract.verify_catalog(File.read(ARGV[0]), File.read(ARGV[1]))
      puts "PASS Android version catalog matches toolchains.lock.json"
    when "artifacts"
      abort "usage: #{File.basename($PROGRAM_NAME)} artifacts LOCK APK_METADATA CXX_MODEL CMAKE_INDEX MANIFEST RESOURCE_TABLE INPUT_METHOD_PATH INPUT_METHOD DATA_EXTRACTION_RULES_PATH DATA_EXTRACTION_RULES" unless ARGV.length == 10
      InkFlow::AndroidBuildContract.verify_artifacts(
        lock_json: File.read(ARGV[0]),
        app_metadata: File.read(ARGV[1]),
        cxx_model_json: File.read(ARGV[2]),
        cmake_index_json: File.read(ARGV[3]),
        manifest_xml: File.read(ARGV[4]),
        resource_table: File.read(ARGV[5]),
        input_method_path: ARGV[6],
        input_method_xml: File.read(ARGV[7]),
        data_extraction_rules_path: ARGV[8],
        data_extraction_rules_xml: File.read(ARGV[9]),
      )
      puts "PASS APK, CXX, CMake, manifest, input-method, and backup-policy artifacts match the lock"
    else
      abort "usage: #{File.basename($PROGRAM_NAME)} {catalog|artifacts} ..."
    end
  rescue InkFlow::AndroidBuildContract::Violation => error
    warn "Android build contract verification failed: #{error.message}"
    exit 1
  end
end
