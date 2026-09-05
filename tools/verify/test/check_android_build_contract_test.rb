#!/usr/bin/env ruby

require "minitest/autorun"
require_relative "../check_android_build_contract"

class CheckAndroidBuildContractTest < Minitest::Test
  LOCK = <<~JSON
    {
      "android": {
        "androidGradlePluginVersion": "9.1.1",
        "compileSdk": 36,
        "targetSdk": 36,
        "minSdk": 26,
        "ndkVersion": "28.2.13676358",
        "cmakeVersion": "3.22.1"
      }
    }
  JSON

  CATALOG = <<~TOML
    [versions]
    agp = "9.1.1"
    compile-sdk = "36"
    target-sdk = "36"
    min-sdk = "26"
    ndk = "28.2.13676358"
    cmake = "3.22.1"
  TOML

  APP_METADATA = <<~PROPERTIES
    appMetadataVersion=1.1
    androidGradlePluginVersion=9.1.1
  PROPERTIES

  CXX_MODEL = <<~JSON
    {
      "info": {"name": "arm64-v8a"},
      "abiPlatformVersion": 26,
      "variant": {
        "buildSystemArgumentList": ["-DANDROID_STL=c++_static"],
        "stlType": "c++_static",
        "validAbiList": ["arm64-v8a"],
        "buildTargetSet": ["inkflow_android_jni"],
        "module": {
          "ndkVersion": "28.2.13676358",
          "cmake": {"cmakeVersionFromDsl": "3.22.1"}
        }
      },
      "fullConfigurationHashKey": "# - AGP: 9.1.1.\\n"
    }
  JSON

  CMAKE_INDEX = <<~JSON
    {"cmake": {"version": {"major": 3, "minor": 22, "patch": 1}}}
  JSON

  MANIFEST = <<~XML
    <manifest xmlns:android="http://schemas.android.com/apk/res/android"
        android:compileSdkVersion="36" package="io.damao.inkflow">
      <uses-sdk android:minSdkVersion="26" android:targetSdkVersion="36" />
      <application android:allowBackup="false" android:fullBackupContent="false"
          android:dataExtractionRules="@ref/0x7f020001"
          android:usesCleartextTraffic="false">
        <service android:name="io.damao.inkflow.ime.InkFlowInputMethodService"
            android:permission="android.permission.BIND_INPUT_METHOD"
            android:exported="true">
          <intent-filter><action android:name="android.view.InputMethod" /></intent-filter>
          <meta-data android:name="android.view.im" android:resource="@ref/0x7f020000" />
        </service>
      </application>
    </manifest>
  XML

  INPUT_METHOD = <<~XML
    <input-method xmlns:android="http://schemas.android.com/apk/res/android"
        android:supportsSwitchingToNextInputMethod="true">
      <subtype android:imeSubtypeMode="keyboard" android:languageTag="zh-Hans-CN" />
    </input-method>
  XML

  DATA_EXTRACTION_RULES = <<~XML
    <data-extraction-rules>
      <cloud-backup>
        <exclude domain="root" path="." />
        <exclude domain="file" path="." />
        <exclude domain="database" path="." />
        <exclude domain="sharedpref" path="." />
        <exclude domain="external" path="." />
        <exclude domain="device_root" path="." />
        <exclude domain="device_file" path="." />
        <exclude domain="device_database" path="." />
        <exclude domain="device_sharedpref" path="." />
      </cloud-backup>
      <device-transfer>
        <exclude domain="root" path="." />
        <exclude domain="file" path="." />
        <exclude domain="database" path="." />
        <exclude domain="sharedpref" path="." />
        <exclude domain="external" path="." />
        <exclude domain="device_root" path="." />
        <exclude domain="device_file" path="." />
        <exclude domain="device_database" path="." />
        <exclude domain="device_sharedpref" path="." />
      </device-transfer>
    </data-extraction-rules>
  XML

  RESOURCE_TABLE = <<~TEXT
    Binary APK
    Package name=io.damao.inkflow id=7f
      type string id=01 entryCount=1
        resource 0x7f010000 string/app_name
          () "InkFlow"
      type xml id=02 entryCount=2
        resource 0x7f020000 xml/input_method
          () (file) res/EJ.xml type=XML
        resource 0x7f020001 xml/data_extraction_rules
          () (file) res/DX.xml type=XML
  TEXT

  def test_accepts_exact_lock_catalog_and_built_artifacts
    contract.verify_catalog(LOCK, CATALOG)
    verify_artifacts
  end

  def test_rejects_every_lock_catalog_drift
    {
      'agp = "9.1.1"' => 'agp = "0.0.0"',
      'compile-sdk = "36"' => 'compile-sdk = "35"',
      'target-sdk = "36"' => 'target-sdk = "35"',
      'min-sdk = "26"' => 'min-sdk = "25"',
      'ndk = "28.2.13676358"' => 'ndk = "0.0.0"',
      'cmake = "3.22.1"' => 'cmake = "0.0.0"',
    }.each do |from, to|
      assert_raises(InkFlow::AndroidBuildContract::Violation) do
        contract.verify_catalog(LOCK, CATALOG.sub(from, to))
      end
    end
  end

  def test_rejects_apk_agp_drift
    assert_raises(InkFlow::AndroidBuildContract::Violation) do
      verify_artifacts(app_metadata: APP_METADATA.sub("9.1.1", "9.2.0"))
    end
  end

  def test_rejects_active_cxx_ndk_and_cmake_drift
    assert_raises(InkFlow::AndroidBuildContract::Violation) do
      verify_artifacts(cxx_model: CXX_MODEL.sub("28.2.13676358", "27.0.0"))
    end
    assert_raises(InkFlow::AndroidBuildContract::Violation) do
      verify_artifacts(cxx_model: CXX_MODEL.sub("3.22.1", "3.23.0"))
    end
    assert_raises(InkFlow::AndroidBuildContract::Violation) do
      verify_artifacts(cxx_model: CXX_MODEL.sub("AGP: 9.1.1", "AGP: 9.2.0"))
    end
    assert_raises(InkFlow::AndroidBuildContract::Violation) do
      verify_artifacts(cmake_index: CMAKE_INDEX.sub('"patch": 1', '"patch": 2'))
    end
  end

  def test_rejects_active_cxx_abi_api_target_and_stl_drift
    [
      CXX_MODEL.sub('"name": "arm64-v8a"', '"name": "x86_64"'),
      CXX_MODEL.sub('"abiPlatformVersion": 26', '"abiPlatformVersion": 27'),
      CXX_MODEL.sub('"inkflow_android_jni"', '"other_target"'),
      CXX_MODEL.sub('"stlType": "c++_static"', '"stlType": "c++_shared"'),
      CXX_MODEL.sub('-DANDROID_STL=c++_static', '-DANDROID_STL=c++_shared'),
    ].each do |drifted_model|
      assert_raises(InkFlow::AndroidBuildContract::Violation) do
        verify_artifacts(cxx_model: drifted_model)
      end
    end
  end

  def test_manifest_tokens_must_belong_to_the_exact_ime_service
    split_contract = MANIFEST
      .sub('android:permission="android.permission.BIND_INPUT_METHOD"', "")
      .sub("</application>", <<~XML)
        <service android:name="example.Decoy"
            android:permission="android.permission.BIND_INPUT_METHOD">
          <intent-filter><action android:name="android.view.InputMethod" /></intent-filter>
          <meta-data android:name="android.view.im" android:resource="@ref/0x7f020000" />
        </service>
        </application>
      XML

    assert_raises(InkFlow::AndroidBuildContract::Violation) do
      verify_artifacts(manifest: split_contract)
    end
  end

  def test_manifest_metadata_must_reference_the_packaged_input_method_resource
    wrong_resource = MANIFEST.sub("@ref/0x7f020000", "@ref/0x7f010000")

    assert_raises(InkFlow::AndroidBuildContract::Violation) do
      verify_artifacts(manifest: wrong_resource)
    end
  end

  def test_resource_table_path_must_be_the_xml_that_was_inspected
    assert_raises(InkFlow::AndroidBuildContract::Violation) do
      verify_artifacts(resource_table: RESOURCE_TABLE.sub("res/EJ.xml", "res/WRONG.xml"))
    end
  end

  def test_qualified_input_method_override_cannot_escape_xml_inspection
    qualified_override = RESOURCE_TABLE.sub(
      "() (file) res/EJ.xml type=XML",
      "() (file) res/EJ.xml type=XML\n      (v31) (file) res/BROKEN.xml type=XML",
    )

    assert_raises(InkFlow::AndroidBuildContract::Violation) do
      verify_artifacts(resource_table: qualified_override)
    end
  end

  def test_qualified_resource_reference_aliases_cannot_escape_xml_inspection
    {
      "() (file) res/EJ.xml type=XML" => "@xml/unsafe_input_method",
      "() (file) res/DX.xml type=XML" => "@xml/unsafe_data_extraction_rules",
    }.each do |default_row, alias_reference|
      qualified_alias = RESOURCE_TABLE.sub(
        default_row,
        "#{default_row}\n      (v31) #{alias_reference}",
      )

      assert_raises(InkFlow::AndroidBuildContract::Violation) do
        verify_artifacts(resource_table: qualified_alias)
      end
    end
  end

  def test_input_method_must_keep_simplified_chinese_and_switching_contracts
    assert_raises(InkFlow::AndroidBuildContract::Violation) do
      verify_artifacts(input_method: INPUT_METHOD.sub("true", "false"))
    end
    assert_raises(InkFlow::AndroidBuildContract::Violation) do
      verify_artifacts(input_method: INPUT_METHOD.sub("zh-Hans-CN", "zh-Hant-TW"))
    end
  end

  def test_manifest_must_reference_the_packaged_data_extraction_rules
    assert_raises(InkFlow::AndroidBuildContract::Violation) do
      verify_artifacts(
        manifest: MANIFEST.sub(' android:dataExtractionRules="@ref/0x7f020001"', ""),
      )
    end
    assert_raises(InkFlow::AndroidBuildContract::Violation) do
      verify_artifacts(
        manifest: MANIFEST.sub("@ref/0x7f020001", "@ref/0x7f020000"),
      )
    end
  end

  def test_data_extraction_resource_path_and_qualifiers_are_exact
    assert_raises(InkFlow::AndroidBuildContract::Violation) do
      verify_artifacts(
        resource_table: RESOURCE_TABLE.sub("res/DX.xml", "res/WRONG.xml"),
      )
    end

    qualified_override = RESOURCE_TABLE.sub(
      "() (file) res/DX.xml type=XML",
      "() (file) res/DX.xml type=XML\n      (v31) (file) res/OVERRIDE.xml type=XML",
    )
    assert_raises(InkFlow::AndroidBuildContract::Violation) do
      verify_artifacts(resource_table: qualified_override)
    end
  end

  def test_data_extraction_rules_deny_every_domain_in_both_modes
    %w[cloud-backup device-transfer].product(backup_domains).each do |section, domain|
      assert_raises(InkFlow::AndroidBuildContract::Violation) do
        verify_artifacts(
          data_extraction_rules: remove_domain(
            DATA_EXTRACTION_RULES,
            section: section,
            domain: domain,
          ),
        )
      end
    end
  end

  def test_data_extraction_rules_reject_includes_and_extra_nodes
    with_include = DATA_EXTRACTION_RULES.sub(
      "</cloud-backup>",
      "  <include domain=\"file\" path=\"allowed\" />\n  </cloud-backup>",
    )
    with_extra_node = DATA_EXTRACTION_RULES.sub(
      "</data-extraction-rules>",
      "  <unexpected />\n</data-extraction-rules>",
    )
    with_extra_exclude = DATA_EXTRACTION_RULES.sub(
      "</device-transfer>",
      "  <exclude domain=\"file\" path=\".\" />\n  </device-transfer>",
    )
    with_extra_attribute = DATA_EXTRACTION_RULES.sub(
      '<exclude domain="root" path="." />',
      '<exclude domain="root" path="." unexpected="true" />',
    )
    with_root_comment = DATA_EXTRACTION_RULES.sub(
      "<data-extraction-rules>",
      "<data-extraction-rules><!-- unexpected -->",
    )
    with_section_text = DATA_EXTRACTION_RULES.sub(
      "<cloud-backup>",
      "<cloud-backup>unexpected",
    )
    with_section_cdata = DATA_EXTRACTION_RULES.sub(
      "<device-transfer>",
      "<device-transfer><![CDATA[unexpected]]>",
    )
    with_processing_instruction = DATA_EXTRACTION_RULES.sub(
      "<cloud-backup>",
      "<cloud-backup><?unexpected value?>",
    )
    with_nested_comment = DATA_EXTRACTION_RULES.sub(
      '<exclude domain="root" path="." />',
      '<exclude domain="root" path="."><!-- unexpected --></exclude>',
    )

    [
      with_include,
      with_extra_node,
      with_extra_exclude,
      with_extra_attribute,
      with_root_comment,
      with_section_text,
      with_section_cdata,
      with_processing_instruction,
      with_nested_comment,
    ].each do |rules|
      assert_raises(InkFlow::AndroidBuildContract::Violation) do
        verify_artifacts(data_extraction_rules: rules)
      end
    end
  end

  private

  def contract
    InkFlow::AndroidBuildContract
  end

  def verify_artifacts(
    app_metadata: APP_METADATA,
    cxx_model: CXX_MODEL,
    cmake_index: CMAKE_INDEX,
    manifest: MANIFEST,
    resource_table: RESOURCE_TABLE,
    input_method_path: "res/EJ.xml",
    input_method: INPUT_METHOD,
    data_extraction_rules_path: "res/DX.xml",
    data_extraction_rules: DATA_EXTRACTION_RULES
  )
    contract.verify_artifacts(
      lock_json: LOCK,
      app_metadata: app_metadata,
      cxx_model_json: cxx_model,
      cmake_index_json: cmake_index,
      manifest_xml: manifest,
      resource_table: resource_table,
      input_method_path: input_method_path,
      input_method_xml: input_method,
      data_extraction_rules_path: data_extraction_rules_path,
      data_extraction_rules_xml: data_extraction_rules,
    )
  end


  def backup_domains
    %w[
      root
      file
      database
      sharedpref
      external
      device_root
      device_file
      device_database
      device_sharedpref
    ]
  end

  def remove_domain(xml, section:, domain:)
    section_pattern = /(<#{Regexp.escape(section)}>.*?)(\s*<exclude domain="#{Regexp.escape(domain)}" path="\." \/>)(.*?<\/#{Regexp.escape(section)}>)/m
    xml.sub(section_pattern, '\\1\\3')
  end
end
