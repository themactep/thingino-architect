require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "json"

require_relative "../lib/thingino_arch"

module FixtureHelper
  def with_repo
    Dir.mktmpdir("thingino-arch-test") do |root|
      write(root, "thingino.mk", "SOC_FAMILY := t31\n")
      write(root, "Config.in", <<~CONFIG)
        menu "Test"
        source "$BR2_EXTERNAL_THINGINO_PATH/package/foo/Config.in"
        source "$BR2_EXTERNAL_THINGINO_PATH/package/wifi/Config.in"
        source "$BR2_EXTERNAL_THINGINO_PATH/package/plugin/Config.in"
        source "$BR2_EXTERNAL_THINGINO_PATH/package/plugin-dupe/Config.in"
        source "$BR2_EXTERNAL_THINGINO_PATH/package/wifi-ok/Config.in"
        source "$BR2_EXTERNAL_THINGINO_PATH/package/wifi-bad/Config.in"
        endmenu
      CONFIG

      write(root, "package/foo/Config.in", <<~CONFIG)
        config BR2_PACKAGE_FOO
        \tbool "foo"
        \tselect BR2_PACKAGE_BAR
      CONFIG
      write(root, "package/foo/foo.mk", <<~MAKE)
        FOO_VERSION = 1.0
        FOO_SITE = https://example.com/foo-$(FOO_VERSION).tar.gz
        FOO_DEPENDENCIES = bar
      MAKE

      write(root, "package/bar/Config.in", "config BR2_PACKAGE_BAR\n\tbool \"bar\"\n")
      write(root, "package/bar/bar.mk", "BAR_SITE = local\n")

      write(root, "package/wifi/Config.in", <<~CONFIG)
        menuconfig BR2_PACKAGE_WIFI
        \tbool "wifi"
        source "$BR2_EXTERNAL_THINGINO_PATH/package/wifi-ok/Config.in"
        source "$BR2_EXTERNAL_THINGINO_PATH/package/wifi-bad/Config.in"
      CONFIG
      write(root, "package/wifi/wifi.mk", "$(eval $(call WIFI_ADD_DRIVER,BR2_PACKAGE_WIFI_OK,okmod,usb))\n")

      write(root, "package/wifi-ok/Config.in", "config BR2_PACKAGE_WIFI_OK\n\tbool \"wifi ok\"\n")
      write(root, "package/wifi-ok/wifi-ok.mk", "WIFI_OK_SITE = local\nWIFI_OK_MODULE_NAME = okmod\n")
      write(root, "package/wifi-bad/Config.in", "config BR2_PACKAGE_WIFI_BAD\n\tbool \"wifi bad\"\n")
      write(root, "package/wifi-bad/wifi-bad.mk", "WIFI_BAD_SITE = local\n")

      write(root, "package/plugin/Config.in", "config BR2_PACKAGE_PLUGIN\n\tbool \"plugin\"\n")
      write(root, "package/plugin/plugin.mk", "PLUGIN_SITE = local\n")
      write(root, "package/plugin/files/plugin.webui.json", JSON.generate("name" => "plugin", "pages" => ["/plugin.html"], "cgi" => ["/x/plugin.cgi"], "featureFlags" => {}))

      write(root, "package/plugin-dupe/Config.in", "config BR2_PACKAGE_PLUGIN_DUPE\n\tbool \"plugin dupe\"\n")
      write(root, "package/plugin-dupe/plugin-dupe.mk", "PLUGIN_DUPE_SITE = local\n")
      write(root, "package/plugin-dupe/files/dupe.webui.json", JSON.generate("name" => "plugin", "pages" => ["/plugin.html"], "cgi" => ["/x/plugin.cgi"], "featureFlags" => {}))

      write(root, "soc/ingenic/t31.mk", <<~MAKE)
        ifneq ($(filter $(SOC_MODEL),t31x),)
        SOC_ARCH := xburst1
        SOC_FAMILY := t31
        SOC_RAM_MB := 64
        endif
      MAKE
      write(root, "kernels/ingenic.mk", "KERNEL_SITE := https://example.com/linux\n")

      write(root, "configs/fragments/core.fragment", "BR2_PACKAGE_FOO=y\n")
      write(root, "configs/cameras/testcam/testcam_defconfig", <<~CONFIG)
        # NAME: Test Camera
        # FRAG: core
        BR2_INGENIC_SOC_MODEL="t31x"
        BR2_SENSOR_1_NAME="gc4653"
        BR2_PACKAGE_WIFI=y
        BR2_PACKAGE_WIFI_OK=y
        BR2_PACKAGE_PLUGIN=y
        BR2_PACKAGE_PLUGIN_DUPE=y
      CONFIG
      write(root, "configs/cameras/testcam/thingino.json", "{}\n")
      write(root, "configs/cameras-testing/qemu_t31x_ethwifi/qemu-test.json", JSON.generate("soc" => "t31x", "caps" => ["wired", "wifi"], "net" => "tap"))
      write(root, "overlay/etc/init.d/S10foo", "#!/bin/sh\n")

      yield ThinginoArch::Repo.new(root), root
    end
  end

  def write(root, path, content)
    full = File.join(root, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, content)
  end
end

class ThinginoArchTest < Minitest::Test
  include FixtureHelper

  def test_index_builds_packages_cameras_and_wifi
    with_repo do |repo, _root|
      index = ThinginoArch::Index.new(repo)
      assert_equal 7, index.packages.size
      assert index.packages["foo"]["remote"]
      assert_equal ["BR2_PACKAGE_FOO"], index.packages["foo"]["main_symbols"]
      assert index.wifi_drivers.key?("BR2_PACKAGE_WIFI_OK")
      assert_equal "okmod", index.wifi_drivers["BR2_PACKAGE_WIFI_OK"]["module_name"]

      camera = index.cameras["cameras/testcam"]
      assert_equal "t31", camera["soc_family"]
      assert_equal ["gc4653"], camera["sensors"]
      assert_equal ["BR2_PACKAGE_WIFI_OK"], camera["wifi_symbols"]
      assert_equal "t31", index.qemu_profiles["qemu_t31x_ethwifi"]["family"]
      assert_includes index.qemu_profiles_by_family["t31"], "qemu_t31x_ethwifi"
      assert_includes camera["selected_packages"], "foo"
      assert_includes camera["selected_packages"], "bar"
      assert_includes camera["selected_packages"], "wifi-ok"
    end
  end

  def test_detects_unreachable_config
    with_repo do |repo, _root|
      findings = ThinginoArch::Checks.new(ThinginoArch::Index.new(repo)).run
      unreachable = findings.select { |finding| finding.id == "package.unreachable_config" }
      assert_equal ["bar"], unreachable.map(&:entity)
    end
  end

  def test_detects_unregistered_wifi_driver
    with_repo do |repo, root|
      write(root, "configs/cameras/testcam/testcam_defconfig", File.read(File.join(root, "configs/cameras/testcam/testcam_defconfig")) + "BR2_PACKAGE_WIFI_BAD=y\n")
      findings = ThinginoArch::Checks.new(ThinginoArch::Index.new(repo)).run
      assert findings.any? { |finding| finding.id == "camera.unregistered_wifi_driver" && finding.entity == "cameras/testcam" }
    end
  end

  def test_detects_unknown_soc
    with_repo do |repo, root|
      write(root, "configs/cameras/testcam/testcam_defconfig", File.read(File.join(root, "configs/cameras/testcam/testcam_defconfig")).sub("t31x", "t99x"))
      findings = ThinginoArch::Checks.new(ThinginoArch::Index.new(repo)).run
      assert findings.any? { |finding| finding.id == "camera.unknown_soc" }
    end
  end

  def test_detects_plugin_conflict
    with_repo do |repo, _root|
      findings = ThinginoArch::Checks.new(ThinginoArch::Index.new(repo)).run
      assert findings.any? { |finding| finding.id == "plugin.duplicate_name" && finding.severity == "error" }
      assert findings.any? { |finding| finding.id == "plugin.duplicate_page" && finding.severity == "error" }
    end
  end

  def test_verification_selects_qemu_profile_and_suites
    with_repo do |repo, _root|
      index = ThinginoArch::Index.new(repo)
      impact = ThinginoArch::Impact.new(index, ["package/plugin/files/plugin.webui.json"])
      plan = ThinginoArch::Verification.new(index, impact, max_profiles: 2)
      assert_equal ["t31"], plan.families
      assert_equal ["qemu_t31x_ethwifi"], plan.profiles.map { |profile| profile["profile"] }
      assert_includes plan.suites.to_a, "webui"
      assert_includes plan.suites.to_a, "playwright"
      assert_includes plan.shell, "qemu_t31x_ethwifi"
      assert_includes plan.shell, "--only health,playwright,services,webui"
      assert_equal ["qemu_t31x_ethwifi"], plan.profiles.map { |profile| profile["profile"] }
      assert_equal(
        ["gh", "workflow", "run", "qemu-test.yaml", "-R", "themactep/thingino-firmware",
         "--ref", "feature", "-f", "profiles=qemu_t31x_ethwifi", "-f", "runner_arch=x86_64"],
        plan.dispatch_command(repo_slug: "themactep/thingino-firmware", ref: "feature")
      )
    end
  end

  def test_impact_maps_package_change_to_camera
    with_repo do |repo, _root|
      index = ThinginoArch::Index.new(repo)
      impact = ThinginoArch::Impact.new(index, ["package/foo/foo.mk"])
      assert_includes impact.to_h["entities"]["packages"], "foo"
      assert_equal ["cameras/testcam"], impact.affected_cameras.map { |camera| camera["id"] }
      assert_includes impact.affected_cameras.first["reasons"], "package:foo"
    end
  end

  def test_baseline_suppresses_existing_findings
    with_repo do |repo, root|
      findings = ThinginoArch::Checks.new(ThinginoArch::Index.new(repo)).run
      path = File.join(root, "baseline.json")
      ThinginoArch::Baseline.write(path, findings)
      baseline = ThinginoArch::Baseline.load(path)
      remaining = findings.reject { |finding| baseline.include?(finding.fingerprint) }
      assert_empty remaining
    end
  end

  def test_ocr_rule_pack_order
    data = JSON.parse(File.read(File.expand_path("../rules/thingino-review.json", __dir__)))
    paths = data["rules"].map { |rule| rule["path"] }
    assert data["include"].any? { |pattern| pattern.include?("mk") }
    assert data["include"].any? { |pattern| pattern.include?("cgi") }
    assert_operator paths.index("**/files/**"), :>, paths.index("**/*.{c,h,cpp,cc,cxx,hpp,hxx}")
    assert_operator paths.index("**/files/**"), :>, paths.index("**/*.{js,jsx,ts,tsx,mjs,cjs,py,pyi,rb}")
    assert_operator paths.index("**/files/**"), :>, paths.index("**/*.hash")
    assert_operator paths.index("**/files/**/*.in"), :<, paths.index("**/files/**")
  end

  def test_changed_scope_keeps_only_package_findings
    with_repo do |repo, root|
      out, = capture_io do
        status = ThinginoArch::CLI.new.run(["check", "--repo", root, "--files", "package/foo/foo.mk", "--changed", "--format", "json"])
        assert_equal 0, status
      end
      result = JSON.parse(out)
      ids = result["findings"].map { |finding| finding["id"] }
      assert_includes ids, "package.missing_hash"
      refute_includes ids, "package.unreachable_config"
      assert_equal 0, result["summary"]["errors"]
    end
  end

  def test_verification_keeps_single_family_change_local
    with_repo do |repo, _root|
      index = ThinginoArch::Index.new(repo)
      impact = ThinginoArch::Impact.new(index, ["soc/ingenic/t31.mk"])
      plan = ThinginoArch::Verification.new(index, impact, max_profiles: 2)
      assert_equal ["t31"], plan.families
      assert_equal ["qemu_t31x_ethwifi"], plan.profiles.map { |profile| profile["profile"] }
    end
  end

  def test_verify_cli_emits_shell_plan
    with_repo do |repo, root|
      out, = capture_io do
        ThinginoArch::CLI.new.run(["verify", "--repo", root, "--files", "package/plugin/files/plugin.webui.json", "--format", "shell"])
      end
      assert_includes out, "make GROUP=testing CAMERA=qemu_t31x_ethwifi fast"
      assert_includes out, "--only health,playwright,services,webui"
    end
  end

  def test_impact_treats_unreferenced_fragment_as_global
    with_repo do |repo, root|
      write(root, "configs/fragments/toolchain/test.fragment", "BR2_TEST=y\n")
      index = ThinginoArch::Index.new(repo)
      impact = ThinginoArch::Impact.new(index, ["configs/fragments/toolchain/test.fragment"])
      assert impact.global
      assert_equal ["cameras/testcam"], impact.affected_cameras.map { |camera| camera["id"] }
    end
  end
end
